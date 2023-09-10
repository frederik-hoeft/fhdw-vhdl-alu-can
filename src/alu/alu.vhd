library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library unisim;
use unisim.vcomponents.all;

entity alu is port (
    -- clock and 1-active synchronous reset
    clk, reset : in std_logic;
    -- 8 bit signed input operands
    a, b : in std_logic_vector(7 downto 0);
    -- the current clock frequency in MHz, used to set the CAN PHY clock frequency
    clk_frequency : in integer range 1 to 255;
    -- arbitration field for CAN protocol (ID + RTR) in base frame format
    can_arbitration : in std_logic_vector(11 downto 0);
    -- 4 bit ALU microcode instruction
    cmd : in std_logic_vector(3 downto 0);
    -- low byte of the ALU result
    flow : out std_logic_vector(7 downto 0);
    -- high byte of the ALU result
    fhigh : out std_logic_vector(7 downto 0);
    -- carry bit, overflow bit, sign bit, equal bit
    -- crc_busy is high-active (i.e. crc_busy = '1' means CRC is busy), crc_busy = '1' means there is an ongoing CRC calculation
    --     and in the next cycle, no new CRC calculation can be started
    -- ready is low-active (i.e. ready = '0' means ready), ready = '1' means ALU is busy in the *next* 
    --     cycle (no new command can be accepted in the following cycle)
    -- can_busy is high-active (i.e. can_busy = '1' means CAN is busy), can_busy = '1' means there is an ongoing CAN transmission
    --     and in the next cycle, no new CAN transmission can be started
    -- can is the serial output of the CAN PHY module
    cout, equal, ov, sign, crc_busy, ready, can, can_busy : out std_logic);
end alu;

architecture alu_beh of alu is
    -- 512x8 bit single point Block SelectRAM for CAN protocol
    component RAMB4_S8 port(
        we : in std_logic; -- Write: Enable: write di to RAM
        en : in std_logic; -- Enable: enable RAM
        rst : in std_logic; -- Reset: set do to 0
        clk : in std_logic; -- Clock: clock input, rising edge
        addr : in std_logic_vector(8 downto 0); -- Address Bus
        di : in std_logic_vector(7 downto 0); -- Data Input Bus
        do : out std_logic_vector(7 downto 0)); -- Data Output Bus
    end component;

    -- generated CRC-15 module, courtesy of https://bues.ch/h/crcgen
    -- implements word-wise CRC-15 calculation at 1 cycle per byte
    -- Polynomial: x^15 + x^14 + x^10 + x^8 + x^7 + x^4 + x^3 + 1
    -- Initial value: 0x0000 using big endian shift order
    component crc15 port (
        -- CRC input (ongoing CRC calculation)
        crcIn: in std_logic_vector(14 downto 0);
        -- Data input (next byte to be CRC'd)
        data: in std_logic_vector(7 downto 0);
        -- CRC output (result of the CRC calculation)
        crcOut: out std_logic_vector(14 downto 0));
    end component;

    -- CAN PHY module / CAN controller
    -- handles buffering of CAN header and data, as well as bit stuffing and serial transmission
    -- at reduced clock frequency of 1 MHz
    -- During the initial buffering phases, CRC and RAM access microcode instructions are unavailable
    -- Execution steps:
    -- Condition: CAN_BUSY = '0', CRC_BUSY = '0'
    -- Cycle 0: "idle" state
    --      - User provides arbitration field (CAN ID + RTR), CAN microcode command, and start/end address for data
    --      - Flag update: CAN_BUSY = '1', CRC_BUSY = '1'
    --      - ALU prepares CRC calculation (header + data)
    --      - ALU caches arbitration field, start/end address
    --      - ALU sets CAN buffer strobe (next cycle: start buffering)
    -- Cycle 1..3: "can buffering" state
    --      - ALU sends arbitration field (3 words, including padding with '0's) to CAN PHY module, CAN PHY module buffers it
    --      - Concurrent CRC calculation (header) of words buffered to CAN PHY module
    --      - In cycle 2, ALU calulates DLC, clamping at 8 bytes, and sends it to CAN PHY module as part of word 3
    --      - In cycle 3, ALU prepares RAM access for data
    -- Cycle 4..4 + DLC: "can crc busy" state
    --      - ALU forwards data from RAM to CAN PHY module, CAN PHY module buffers it
    --      - Concurrent CRC calculation (data) of words buffered to CAN PHY module
    --      - second to last cycle: 
    --          - ALU sets CAN CRC strobe (next cycle: read CRC result)
    --      - last cycle: 
    --          - ALU reports CRC not busy (new CRC calculation can be started in the next cycle)
    --          - CAN PHY reads CRC result
    -- Cycle 5 + DLC: "CAN NOP cycle"
    --      - CAN PHY module switches from Mealy (optimized for reduced cycles during buffering) to Moore FSM ("transmission" mode)
    --      - CAN PHY prepares internal counters, stuffing logic, and serial transmission
    -- Cycle 6 + DLC.. "CAN transmission" state
    --      - CAN PHY reduces clock frequency to 1 MHz and starts serial transmission: SOF, arbitration field, DLC, data, CRC, EOF
    -- 
    -- After cycle 0 (immediately after dispatching the CAN microcode command), the ALU is free to accept any new command
    -- that does not involve CAN, RAM, or CRC. CAN is considered a non-blocking operation.
    component can_phy is port(
        -- clk, reset: clock and reset
        -- buffer_strobe: high-active strobe for CAN to start buffering words from the ALU via parallel_in
        -- crc_strobe: high-active strobe for CAN to read the CRC result from the ALU via crc_in
        clk, buffer_strobe, crc_strobe, reset : in std_logic;
        -- the current clock frequency in MHz, used to throttle the CAN PHY clock frequency
        -- to transmission speeds acceptable by the CAN bus
        clk_frequency : in integer range 1 to 255;
        crc_in : in std_logic_vector(14 downto 0);
        -- parallel_in: 8 bit parallel input from the ALU, first 5 bits of the first word are padded with '0's
        parallel_in : in std_logic_vector(7 downto 0);
        -- serial_out: serial output to the CAN bus, including SOF, IFS, and bit stuffing
        serial_out : out std_logic;
        -- busy: high-active signal indicating that CAN is busy (i.e. there is an ongoing CAN transmission)
        -- during CAN transmission, the ALU is blocked from accepting any new CAN microcode commands
        -- attempts to start a new CAN transmission will be ignored
        -- it is the responsibility of the user to ensure that CAN is not busy before starting a new CAN transmission
        busy : out std_logic);
    end component;

    -- FSM things
    type state_type is (
        -- idle state, ready to accept any new command
        s_idle, 
        -- CRC calculation is running, ALU is blocked from accepting any new CRC, RAM, or CAN microcode commands
        -- any other microcode commands are allowed
        s_crc_busy, 
        -- CAN is buffering header, ALU is blocked from accepting any new CRC, RAM, or CAN microcode commands
        s_can_buffering, 
        -- CAN is buffering data, ALU is blocked from accepting any new CRC, RAM, or CAN microcode commands
        s_can_crc_busy, 
        -- CAN is transmitting, ALU is blocked from accepting any new CAN microcode commands
        s_can_transmitting);

    signal state : state_type := s_idle;
    signal next_state : state_type := s_idle;

    -- 9 bit Address Bus for RAM
    signal ram_addr : std_logic_vector(8 downto 0) := (others => '0');

    -- RAM control signals
    signal ram_we : std_logic := '0';
    signal ram_di, ram_do : std_logic_vector(7 downto 0) := (others => '0');

    -- signal for storing the command
    -- 0000: flow = a + b
    -- 0001: flow = a - b
    -- 0010: flow = (a + b) * 2
    -- 0011: flow = (a + b) * 4
    -- 0100: flow = -a
    -- 0101: flow = a << 1
    -- 0110: flow = a >> 1
    -- 0111: flow = a <<< 1 (rotate left)
    -- 1000: flow = a >>> 1 (rotate right)
    -- 1001: flow = a * b
    -- 1010: flow = ~(a & b) (bitwise nand)
    -- 1011: flow = a ^ b (bitwise xor)
    -- 1100: RAM [b] = a
    -- 1101: flow = CRC RAM [a..b]
    -- 1110: can = can_reg concat RAM [a..b] (serial)
    -- 1111: RESERVED (interpreted as NOP)
    signal reg_cmd : std_logic_vector(3 downto 0) := (others => '0');

    -- registers for storing the CAN DLC, as calculated from the start and end address
    signal can_dlc, can_dlc_next : std_logic_vector(3 downto 0) := (others => '0');
    
    -- register for synchronizing the user-provided CAN arbitration field (ID + RTR)
    signal reg_can_arbitration : std_logic_vector(11 downto 0) := (others => '0');

    -- register for storing the CAN arbitration field while it is being buffered to the CAN PHY module
    signal can_arbitration_buffer, can_arbitration_buffer_next : std_logic_vector(11 downto 0) := (others => '0');

    -- registers for synchronizing the user-provided input values
    signal reg_a, reg_b : signed(7 downto 0) := (others => '0');

    -- signal for expanding the 8 bit input values to 16 bit
    -- also handles sign extension
    signal a_exp, b_exp : signed(15 downto 0) := (others => '0');

    -- registers for storing the CRC calculation state
    -- includes the current CRC value, the current RAM address, and the end address
    signal crc_current, crc_next, crc_out : std_logic_vector(14 downto 0) := (others => '0');
    signal crc_pointer, crc_pointer_next : unsigned(8 downto 0) := (others => '0');
    signal crc_end_pointer, crc_end_pointer_next : unsigned(7 downto 0) := (others => '0');

    -- whether or not CRC is done by the end of the current cycle
    signal crc_done : boolean;

    -- corrected CRC busy signal to work around the Mealy FSM
    -- shifts the CRC busy signal by 1 cycle to unblock the CRC calculation state faster
    signal crc_busy_corrected : std_logic;

    -- if the CRC is done by the end of the next cycle, then we cannot allow
    -- the next cycle to perform any operations, as the result buffer will be
    -- overwritten by the CRC result
    signal crc_done_next_cycle : boolean;

    -- inclusive upper bound for the CAN header buffer (in bits, including padding)
    constant CAN_HEADER_MAX : integer := 23;

    -- a virtual register for assembling the CAN header
    -- first 5 bits are padding, next bit is the start of frame bit
    -- some bits are filled with constant values (e.g. padding, SOF, IDE, R0)
    signal can_header : std_logic_vector(CAN_HEADER_MAX downto 0);
    
    -- the CAN header is buffered to the CAN PHY module in 3 words (2, 1, 0)
    constant CAN_HEADER_RAW_MAX : unsigned(1 downto 0) := "10";

    -- how many words of the CAN header have been pushed to the CAN PHY module so far?
    -- the header pointer is decremented by 1 word every cycle during CAN header buffering
    -- and it points to the upper bound of each word, so bits 23, 15, and 7
    signal can_header_pointer : integer range CAN_HEADER_MAX downto 0;
    -- we therefore only need 2 bits to represent the header pointer
    -- the lower 3 bits are then just filled with '1's
    signal can_header_pointer_raw : unsigned(1 downto 0) := CAN_HEADER_RAW_MAX;
    signal can_header_pointer_raw_next : unsigned(1 downto 0) := CAN_HEADER_RAW_MAX;

    -- CAN controller control signals
    -- CAN we start another CAN transmission? (pun intended)
    signal can_busy_out : std_logic := '0';
    signal can_parallel_in : std_logic_vector(7 downto 0) := (others => '0');
    signal can_buffer_strobe : std_logic := '0';
    signal can_crc_strobe : std_logic := '0';
    
    -- synchonized user-provided clock frequency, used to update CAN transmission speed
    -- theoretically supports dynamic clock frequency changes, but not tested
    signal reg_clk_frequency : integer range 1 to 255;
    
    -- signal for storing the output values (signed 16 bit)
    -- 16 bit signed big endian output, MSB first
    signal result : signed(15 downto 0) := (others => '0');
begin
    -- instantiate the RAM
    ram : RAMB4_S8 port map(
        we => ram_we,
        en => '1',
        rst => '0',
        clk => clk,
        addr => ram_addr,
        di => ram_di,
        do => ram_do);
    
    -- instantiate the CRC-15 module
    crc : crc15 port map(
        crcIn => crc_current,
        -- CAN parallel input is either the CAN header or RAM output anyway
        -- so we can just use the same signal, reducing the number of signals
        -- the only difference from CAN CRC and explicit CRC is that CAN CRC
        -- consumes the header as well and that the output is routed differently
        data => can_parallel_in,
        crcOut => crc_out);

    -- instantiate the CAN PHY module
    can_controller : can_phy port map(
        clk => clk,
        buffer_strobe => can_buffer_strobe,
        clk_frequency => reg_clk_frequency,
        crc_strobe => can_crc_strobe,
        reset => reset,
        crc_in => crc_out,
        parallel_in => can_parallel_in,
        serial_out => can,
        busy => can_busy_out);
    
    -- fill the lower 3 bits of the CAN header pointer with '1's, basically multiplying by 8 and then subtracting 1
    -- header pointer will start at 23, then 15, then 7, and finally underflow to 31.
    can_header_pointer <= to_integer(unsigned(std_logic_vector(can_header_pointer_raw) & "111"));

    -- process for storing the command and the input values
    snap_inputs : process(clk)
    begin
        if rising_edge(clk) then
            reg_cmd <= cmd;
            reg_a <= signed(a);
            reg_b <= signed(b);
            reg_can_arbitration <= can_arbitration;
            reg_clk_frequency <= clk_frequency;
        end if;
    end process;

    -- sign expansion for input values, allowing 16 bit operations
    -- this is faster than resizing the results seperately to 16 bit.
    a_exp <= resize(reg_a, 16);
    b_exp <= resize(reg_b, 16);

    -- updates all the registers
    refresh_state : process(clk, reset)
    begin
        if (rising_edge(clk)) then
            if (reset = '1') then
                state <= s_idle;
                crc_pointer <= (others => '0');
                crc_current <= (others => '0');
                can_header_pointer_raw <= CAN_HEADER_RAW_MAX;
                can_dlc <= (others => '0');
                can_arbitration_buffer <= (others => '0');
            else
                state <= next_state;
                crc_pointer <= crc_pointer_next;
                crc_current <= crc_next;
                crc_end_pointer <= crc_end_pointer_next;
                can_header_pointer_raw <= can_header_pointer_raw_next;
                can_dlc <= can_dlc_next;
                can_arbitration_buffer <= can_arbitration_buffer_next;
            end if;
        end if;
    end process;
    
    -- CRC is done when the CRC pointer is at the end address
    -- the next cycle is when the CRC result is ready
    crc_done <= crc_pointer >= crc_end_pointer;

    -- process for calculating the next state
    transition : process(state, reg_cmd, crc_done, can_busy_out, can_header_pointer_raw)
    begin
        case state is
            when s_idle =>
                case reg_cmd is
                    when "1101" =>
                        -- only allow CRC calculation if CRC is not busy
                        next_state <= s_crc_busy;
                    when "1110" =>
                        -- only allow CAN transmission if CAN is not busy
                        next_state <= s_can_buffering;
                    when others =>
                        -- all other operations are single cycle
                        -- and this is a Mealy FSM, so we can just go back to idle
                        next_state <= s_idle;
                end case;
            when s_crc_busy =>
                if (crc_done) then
                    -- we allow CRC calculation while CAN is busy
                    -- so don't "forget" about the CAN operation
                    if (can_busy_out = '1') then
                        next_state <= s_can_transmitting;
                    else
                        -- otherwise, go back to idle
                        next_state <= s_idle;
                    end if;
                else
                    next_state <= s_crc_busy;
                end if;
            when s_can_buffering =>
                -- CAN header pointer (upper bound) is decremented by 1 word every cycle during CAN header buffering
                -- if it reaches 0, then we are done buffering the CAN header
                if (can_header_pointer_raw = 0) then
                    next_state <= s_can_crc_busy;
                else
                    next_state <= s_can_buffering;
                end if;
            when s_can_crc_busy =>
                -- CAN is starting to transmit the buffered CAN data
                -- we can't start another CAN transmission until the current one is done
                -- so switch to CAN transmitting state, with reduced ALU functionality
                -- (no CAN operations allowed during CAN transmission)
                if (crc_done) then
                    next_state <= s_can_transmitting;
                else
                    next_state <= s_can_crc_busy;
                end if;
            when s_can_transmitting =>
                -- CAN transmission is running, but CRC module is idle
                if (reg_cmd = "1101") then
                    next_state <= s_crc_busy;
                elsif (can_busy_out = '1') then
                    next_state <= s_can_transmitting;
                else
                    next_state <= s_idle;
                end if;
            when others =>
                report "ALU transition: UNKNOWN STATE" severity error;
                next_state <= s_idle;
        end case;
    end process transition;

    -- update the ongoing CRC sum to be fed back into the CRC module in the next cycle
    set_crc_next: process(state, crc_out)
    begin
        if (state = s_crc_busy or state = s_can_crc_busy or state = s_can_buffering) then
            -- feed the CRC module with the ongoing CRC calculation as long as we are in the CRC calculation state
            crc_next <= crc_out;
        else
            -- reset CRC
            crc_next <= (others => '0');
        end if;
    end process;

    -- update the pointer to the end address of the CRC calculation
    set_crc_end_pointer_next: process(state, reg_cmd, reg_a, reg_b, crc_end_pointer)
    begin
        if (state = s_idle and reg_cmd = "1110") then
            -- snap CRC end address, clamp at 8 bytes if this is a CAN operation
            if (reg_b - reg_a > 7) then
                crc_end_pointer_next <= unsigned(reg_a) + 7;
            else
                crc_end_pointer_next <= unsigned(reg_b);
            end if;
        elsif ((state = s_idle or state = s_can_transmitting) and reg_cmd = "1101") then
            -- snap CRC end address, normal CRC operation, no length restriction
            crc_end_pointer_next <= unsigned(reg_b);
        else
            -- keep the end address
            crc_end_pointer_next <= crc_end_pointer;
        end if;
    end process;

    set_crc_pointer_next: process(state, reg_cmd, crc_pointer, reg_a)
    begin
        if ((state = s_idle or state = s_can_transmitting) and reg_cmd = "1101") then
            -- snap CRC start address
            crc_pointer_next <= resize(unsigned(reg_a), 9);
        elsif (state = s_idle and reg_cmd = "1110") then
            -- snap CRC start address
            crc_pointer_next <= resize(unsigned(reg_a), 9);
        elsif (state = s_crc_busy or state = s_can_crc_busy) then
            -- increment CRC address
            crc_pointer_next <= crc_pointer + 1;
        else
            -- hold address
            crc_pointer_next <= crc_pointer;
        end if;
    end process;

    set_ram_addr: process(state, reg_cmd, reg_a, reg_b, crc_pointer)
    begin
        if ((state = s_idle or state = s_can_transmitting) and reg_cmd = "1100") then
            ram_addr <= std_logic_vector("0" & reg_b); -- write to RAM
        elsif ((state = s_idle or state = s_can_transmitting) and reg_cmd = "1101") then
            ram_addr <= std_logic_vector("0" & reg_a); -- prepare CRC calculation
        elsif (state = s_can_buffering) then
            ram_addr <= std_logic_vector(crc_pointer);
        elsif (state = s_crc_busy or state = s_can_crc_busy) then
            ram_addr <= std_logic_vector(crc_pointer + 1);
        else
            ram_addr <= (others => '0');
        end if;
    end process;

    set_crc_busy : process(state, reg_cmd, crc_done)
    begin
        if (((state = s_crc_busy or state = s_can_crc_busy) and not crc_done) -- calculating CRC right now and not done by the end of the cycle
            or ((state = s_idle or state = s_can_transmitting) and (reg_cmd = "1101" or reg_cmd = "1110")) -- CRC calculation requested by user, starting next cycle
            or state = s_can_buffering) then -- CAN header is being buffered, CRC calculation is running in parallel 
            crc_busy_corrected <= '1';
        else
            crc_busy_corrected <= '0';
        end if;
    end process;

    -- output CRC busy signal
    crc_busy <= crc_busy_corrected;

    -- if the CRC is done by the end of the next cycle, then we cannot allow
    -- the next cycle to perform any operations, as the result buffer will be
    -- overwritten by the CRC result
    crc_done_next_cycle <= crc_pointer + 1 = crc_end_pointer;
    
    -- ready is low-active (i.e. ready = '0' means ready)
    set_ready : process(state, reg_cmd, crc_done_next_cycle, reg_a, reg_b)
    begin
        if (state = s_crc_busy and crc_done_next_cycle) then
            -- whether we are to accept a new command depends on whether the CRC result will be ready by the end of the next cycle
            ready <= '1';
        elsif ((state = s_idle or state = s_can_transmitting) and reg_cmd = "1101" and reg_a = reg_b) then
            -- it is also possible that only one byte is to be CRC'd
            -- in this case, the CRC result will be ready by the end of the next cycle, 
            -- even though we are not even in s_crc_busy state yet
            ready <= '1';
        else
            ready <= '0';
        end if;
    end process;

    -- concatenate the CAN arbitration field and other CAN header fields
    --            PADDING   SOF          ID + RTR       IDE + R0    DLC
    can_header <= "00000" & "0" & can_arbitration_buffer & "00" & can_dlc;

    -- buffer the CAN arbitration field
    set_can_arbitration_buffer : process(state, reg_cmd, reg_can_arbitration, can_arbitration_buffer)
    begin
        if (state = s_idle and reg_cmd = "1110") then
            -- update from input
            can_arbitration_buffer_next <= reg_can_arbitration;
        else
            -- keep the buffer
            can_arbitration_buffer_next <= can_arbitration_buffer;
        end if;
    end process;

    -- update the pointer used to push the CAN header to the CAN module
    set_can_header_pointer_raw : process(state, reg_cmd, can_header_pointer_raw)
    begin
        if ((state = s_idle and reg_cmd = "1110") or state = s_can_buffering) then
            -- operate in network byte order (big endian) and decrement by 8 every cycle
            can_header_pointer_raw_next <= can_header_pointer_raw - 1;
        else
            can_header_pointer_raw_next <= CAN_HEADER_RAW_MAX;
        end if;
    end process;

    set_can_buffer_strobe : process(state, reg_cmd)
    begin
        if (state = s_idle and reg_cmd = "1110") then
            can_buffer_strobe <= '1'; -- start buffering (next cycle will start pushing data to the CAN PHY)
        elsif (state = s_can_buffering) then
            can_buffer_strobe <= '1'; -- we are currently buffering the CAN header
        elsif (state = s_can_crc_busy) then
            can_buffer_strobe <= '1'; -- we are currently buffering the CAN data
        else
            can_buffer_strobe <= '0';
        end if;
    end process;

    set_can_crc_strobe : process(state, crc_done)
    begin
        if (state = s_can_crc_busy and crc_done) then
            can_crc_strobe <= '1'; -- read the CRC result with the next clock cycle (CRC will be ready by then)
        else
            can_crc_strobe <= '0';
        end if;
    end process;

    -- it's a Mealy FSM, so everything is faster by 1 cycle
    set_can_parallel_in : process(state, can_header_pointer, reg_cmd, can_header, ram_do)
    begin
        if ((state = s_idle and reg_cmd = "1110") or state = s_can_buffering) then
            -- buffer the CAN header
            can_parallel_in <= can_header(can_header_pointer downto can_header_pointer - 7);
        else 
            -- otherwise, buffer the data from the RAM
            can_parallel_in <= ram_do;
        end if;
    end process;

    set_reg_can_dlc : process(state, can_header_pointer_raw, crc_pointer, crc_end_pointer, can_dlc)
    begin
        if (state = s_can_buffering and can_header_pointer_raw = 1) then
            -- write the data length code to the CAN header (only possible in the second cycle of buffering)
            can_dlc_next <= std_logic_vector(resize(unsigned(crc_end_pointer - crc_pointer + 1), 4));
        else
            -- otherwise, keep the data length code
            can_dlc_next <= can_dlc;
        end if;
    end process set_reg_can_dlc;
    
    set_can_busy: process(state, reg_cmd, can_busy_out)
    begin
        if (state = s_idle and reg_cmd = "1110") then
            -- prevent another CAN operation from being started
            -- at this point, CAN hasn't started yet, but it will start in the next cycle
            -- so no new CAN operations for now
            can_busy <= '1';
        else
            can_busy <= can_busy_out;
        end if;
    end process set_can_busy;

    ram_di <= std_logic_vector(reg_a);

    set_ram_write: process(state, reg_cmd, reg_a)
    begin
        if ((state = s_idle or state = s_can_transmitting) and reg_cmd = "1100") then
            ram_we <= '1';
        else 
            ram_we <= '0';
        end if;
    end process;

    -- process for setting the result
    set_result : process(state, reg_cmd, a_exp, b_exp, reg_a, reg_b, crc_out, crc_done)
    begin
        if (state = s_crc_busy and crc_done) then
            -- CRC interrupt, result is ready
            result <= signed("0" & crc_out);
        else
            -- we are in any other state and it's safe to set the result
            -- CRC output won't conflict with the result buffer
            -- so we can use the result buffer for other operations
            case reg_cmd is
                when "0000" => -- flow = a + b
                    result <= a_exp + b_exp;
                when "0001" => -- flow = a - b
                    result <= a_exp - b_exp;
                when "0010" => -- flow = (a + b) * 2
                    -- it was not specified whether the result should be 8 bit or 16 bit
                    -- so we assume 16 bit, to not have to deal with overflows :)
                    result <= (a_exp + b_exp) sll 1; -- 16 bit OP & assuming big endian
                when "0011" => -- flow = (a + b) * 4
                    -- it was not specified whether the result should be 8 bit or 16 bit
                    -- so we assume 16 bit, to not have to deal with overflows :)
                    result <= (a_exp + b_exp) sll 2; -- 16 bit OP & assuming big endian
                when "0100" => -- flow = -a
                    result <= -a_exp;
                when "0101" => -- flow = a << 1
                    result <= a_exp sll 1;
                when "0110" => -- flow = a >> 1
                    result <= a_exp srl 1;
                when "0111" => -- flow = a <<< 1 (rotate left)
                    result <= resize(reg_a rol 1, 16);
                when "1000" => -- flow = a >>> 1 (rotate right)
                    result <= resize(reg_a ror 1, 16);
                when "1001" => -- flow = a * b
                    result <= reg_a * reg_b;
                when "1010" => -- flow = ~(a & b) (bitwise nand)
                    result <= a_exp nand b_exp;
                when "1011" => -- flow = a ^ b (bitwise xor)
                    result <= a_exp xor b_exp;
                when others =>
                    result <= (others => '0');
            end case;
        end if;
    end process set_result;

    -- output the result
    flow <= std_logic_vector(result(7 downto 0));
    fhigh <= std_logic_vector(result(15 downto 8));

    -- output flag processing
    set_equal : process(a_exp, b_exp)
    begin
        if a_exp = b_exp then
            equal <= '1';
        else
            equal <= '0';
        end if;
    end process;

    set_cout : process(reg_cmd, reg_a, reg_b)
    begin
        if (reg_cmd = "0000" and (unsigned(("0" & reg_a) + ("0" & reg_b)) > 255)) then
            cout <= '1';
        elsif (reg_cmd = "0001" and unsigned(reg_a) < unsigned(reg_b)) then
            cout <= '1';
        elsif (reg_cmd = "0100" and reg_a /= -128) then
            cout <= not reg_a(7);
        else
            cout <= '0';
        end if;
    end process;

    set_ov : process(reg_cmd, result)
    begin
        -- set ov for add, sub, neg
        -- cheat by using 16 bits :)
        if ((reg_cmd = "0000" or reg_cmd = "0001" or reg_cmd = "0100") and (result > 127 or result < -128)) then
            ov <= '1';
        else
            ov <= '0';
        end if;
    end process;

    set_sign : process(reg_cmd, result)
    begin
        if (reg_cmd = "0010" or reg_cmd = "0011" or reg_cmd = "1001") then
            -- 16 bit ops
            sign <= result(15);
        else 
            -- 8 bit ops
            sign <= result(7);
        end if;
    end process;

end alu_beh;

