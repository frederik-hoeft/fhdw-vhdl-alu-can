library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library unisim;
use unisim.vcomponents.all;

entity alu is port (
    clk, reset : in std_logic;
    a, b : in std_logic_vector(7 downto 0);
    can_arbitration : in std_logic_vector(11 downto 0);
    cmd : in std_logic_vector(3 downto 0);
    flow : out std_logic_vector(7 downto 0);
    fhigh : out std_logic_vector(7 downto 0);
    -- TODO: crc strobe
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

    -- generated CRC-15 module
    component crc15 port (
        crcIn: in std_logic_vector(14 downto 0);
        data: in std_logic_vector(7 downto 0);
        crcOut: out std_logic_vector(14 downto 0));
    end component;

    -- CAN PHY module / CAN controller
    component can_phy is port(
        clk, buffer_strobe, crc_strobe, reset : in std_logic;
        crc_in : in std_logic_vector(14 downto 0);
        parallel_in : in std_logic_vector(7 downto 0);
        serial_out : out std_logic;
        busy : out std_logic);
    end component;

    type state_type is (s_idle, s_crc_busy, s_can_buffering, s_can_crc_busy, s_can_transmitting);

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
    -- 1111: RESERVED
    signal reg_cmd : std_logic_vector(3 downto 0) := (others => '0');

    signal can_dlc, can_dlc_next : std_logic_vector(3 downto 0) := (others => '0');
    
    signal reg_can_arbitration : std_logic_vector(11 downto 0) := (others => '0');

    signal can_arbitration_buffer, can_arbitration_buffer_next : std_logic_vector(11 downto 0) := (others => '0');

    signal can_header : std_logic_vector(18 downto 0);

    -- registers for storing the input values
    signal reg_a, reg_b : signed(7 downto 0) := (others => '0');

    -- signal for expanding the 8 bit input values to 16 bit
    signal a_exp, b_exp : signed(15 downto 0) := (others => '0');

    signal crc_current, crc_next, crc_out : std_logic_vector(14 downto 0) := (others => '0');
    signal crc_pdata, crc_pnext : unsigned(8 downto 0) := (others => '0');
    signal crc_pend, crc_pend_next : unsigned(7 downto 0) := (others => '0');

    signal crc_done : boolean;
    signal crc_busy_corrected : std_logic;

    -- if the CRC is done by the end of the next cycle, then we cannot allow
    -- the next cycle to perform any operations, as the result buffer will be
    -- overwritten by the CRC result
    signal crc_done_next_cycle : boolean;

    -- how many words of the CAN header have been buffered so far
    signal can_header_pointer : integer range 0 to 19 := 0;
    signal can_header_pointer_next : integer range 0 to 19 := 0;
    constant CAN_HEADER_LENGTH : integer := 19;
    -- CAN we start another CAN transmission? (pun intended)
    signal can_busy_out : std_logic := '0';
    signal can_parallel_in : std_logic_vector(7 downto 0) := (others => '0');
    signal can_buffer_strobe : std_logic := '0';
    signal can_crc_strobe : std_logic := '0';

    -- signal for storing the output values (signed 16 bit)
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
        data => ram_do,
        crcOut => crc_out);

    -- instantiate the CAN PHY module
    can_controller : can_phy port map(
        clk => clk,
        buffer_strobe => can_buffer_strobe,
        crc_strobe => can_crc_strobe,
        reset => reset,
        crc_in => crc_out,
        parallel_in => can_parallel_in,
        serial_out => can,
        busy => can_busy_out);

    -- process for storing the command and the input values
    snap_inputs : process(clk, state)
    begin
        if rising_edge(clk) then
            reg_cmd <= cmd;
            reg_a <= signed(a);
            reg_b <= signed(b);
            reg_can_arbitration <= can_arbitration;
        end if;
    end process;

    a_exp <= resize(reg_a, 16);
    b_exp <= resize(reg_b, 16);

    refresh_state : process(clk, reset)
    begin
        if (rising_edge(clk)) then
            if (reset = '1') then
                state <= s_idle;
                crc_pdata <= (others => '0');
                crc_current <= (others => '0');
                crc_pend <= (others => '0');
                can_header_pointer <= 0;
                -- reset the CAN header register to dummy header from Wikipedia
                can_dlc <= "0000";
                can_arbitration_buffer <= (others => '0');
            else
                state <= next_state;
                crc_pdata <= crc_pnext;
                crc_current <= crc_next;
                crc_pend <= crc_pend_next;
                can_header_pointer <= can_header_pointer_next;
                can_dlc <= can_dlc_next;
                can_arbitration_buffer <= can_arbitration_buffer_next;
            end if;
        end if;
    end process;
    
    crc_done <= crc_pdata >= crc_pend;

    -- process for calculating the next state
    transition : process(state, reg_cmd, crc_done, can_busy_out, can_header_pointer)
    begin
        case state is
            when s_idle =>
                case reg_cmd is
                    when "1101" =>
                        next_state <= s_crc_busy;
                    when "1110" =>
                        next_state <= s_can_buffering;
                    when others =>
                        next_state <= s_idle;
                end case;
            when s_crc_busy =>
                if (crc_done) then
                    if (can_busy_out = '1') then
                        next_state <= s_can_transmitting;
                    else
                        next_state <= s_idle;
                    end if;
                else
                    next_state <= s_crc_busy;
                end if;
            when s_can_buffering =>
                if (can_header_pointer >= CAN_HEADER_LENGTH - 8) then
                    next_state <= s_can_crc_busy;
                else
                    next_state <= s_can_buffering;
                end if;
            when s_can_crc_busy =>
                if (crc_done) then
                    next_state <= s_can_transmitting;
                else
                    next_state <= s_can_crc_busy;
                end if;
            when s_can_transmitting =>
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

    crc_transition: process(state, reg_cmd, crc_pdata, crc_pend, reg_a, reg_b, crc_out)
    begin
        if ((state = s_idle or state = s_can_transmitting) and reg_cmd = "1101") then
            -- snap CRC start and end address
            -- initialize CRC
            crc_pnext <= resize(unsigned(reg_a), 9);
            crc_pend_next <= unsigned(reg_b);
            crc_next <= (others => '0'); -- reset CRC IV
        elsif (state = s_idle and reg_cmd = "1110") then
            -- snap CRC start and end address, capping at 8 bytes
            crc_pnext <= resize(unsigned(reg_a), 9);
            if (reg_b - reg_a > 7) then
                crc_pend_next <= unsigned(reg_a) + 7;
            else
                crc_pend_next <= unsigned(reg_b);
            end if;
            -- initialize CRC
            crc_next <= (others => '0'); -- reset CRC IV
        elsif (state = s_crc_busy or state = s_can_crc_busy) then
            -- increment CRC address, update CRC, and keep end address
            crc_pnext <= crc_pdata + 1;
            crc_next <= crc_out;
            crc_pend_next <= crc_pend;
        elsif (state = s_can_buffering) then
            -- wait for the CAN header to be buffered, hold addresses, and initialize CRC
            crc_pnext <= crc_pdata;
            crc_pend_next <= crc_pend;
            crc_next <= (others => '0'); -- reset CRC IV
        else
            -- reset CRC
            crc_pnext <= (others => '0');
            crc_next <= (others => '0');
            crc_pend_next <= (others => '0');
        end if;
    end process;

    set_crc_busy : process(state, reg_cmd, crc_done, can_header_pointer)
    begin
        if (((state = s_crc_busy or state = s_can_crc_busy) and not crc_done) -- calculating CRC right now and not done by the end of the cycle
            or ((state = s_idle or state = s_can_transmitting) and reg_cmd = "1101") -- CRC calculation requested by user, starting next cycle
            or (state = s_can_buffering and can_header_pointer = CAN_HEADER_LENGTH)) then -- CRC calculation requested by CAN, starting next cycle
            crc_busy_corrected <= '1';
        else
            crc_busy_corrected <= '0';
        end if;
    end process;

    crc_busy <= crc_busy_corrected;

    crc_done_next_cycle <= crc_pdata + 1 = crc_pend;
    
    -- ready is low-active (i.e. ready = '0' means ready)
    set_ready : process(state, reg_cmd, crc_busy_corrected)
    begin
        if (state = s_can_buffering) then
            ready <= '1'; -- we are using resources to buffer the CAN header, so we are not ready
        else
            -- whether we are to accept a new command depends on whether the CRC result will be ready by the end of the next cycle
            ready <= crc_done_next_cycle;
        end if;
    end process;

    -- buffer the CAN arbitration field
    set_can_arbitration_buffer : process(state, reg_cmd, reg_can_arbitration, can_arbitration_buffer)
    begin
        if (state = s_idle and reg_cmd = "1110") then
            can_arbitration_buffer_next <= reg_can_arbitration;
        else
            can_arbitration_buffer_next <= can_arbitration_buffer;
        end if;
    end process;

    set_can_header_pointer : process(state, reg_cmd, can_header_pointer)
    begin
        -- the can header is 19 bits long, and we buffer in words of 8 bits
        -- so we need to buffer 3 words and then start the CRC calculation
        if (state = s_idle and reg_cmd = "1110") then
            -- the first word only contains 19 % 8 = 3 bits of the header
            can_header_pointer_next <= 3;
        elsif (state = s_can_buffering) then
            can_header_pointer_next <= can_header_pointer + 8;
        else
            can_header_pointer_next <= 0;
        end if;
    end process;

    set_can_buffer_strobe : process(state, reg_cmd, crc_done)
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
        if (state = s_idle and reg_cmd = "1110") then
            -- start buffering the CAN header
            -- the first word only contains 19 % 8 = 3 bits of the header
            can_parallel_in <= "00000" & can_header(18 downto 16);
        elsif (state = s_can_buffering and can_header_pointer < CAN_HEADER_LENGTH) then
            -- buffer the rest of the CAN header
            can_parallel_in <= can_header(18 - can_header_pointer downto 18 - can_header_pointer - 7);
        else 
            -- otherwise, buffer the data from the RAM
            can_parallel_in <= ram_do;
        end if;
    end process;

    set_reg_can_dlc : process(state, can_header_pointer, crc_pdata, crc_pend, can_dlc)
    begin
        if (state = s_can_buffering and can_header_pointer = 3) then
            -- write the data length code to the CAN header
            can_dlc_next <= std_logic_vector(resize(unsigned(crc_pend - crc_pdata + 1), 4));
        else
            can_dlc_next <= can_dlc;
        end if;
    end process set_reg_can_dlc;
    
    -- concatenate the CAN arbitration field and the CAN header
    --            SOF          ID + RTR       IDE + R0    DLC
    can_header <= "0" & can_arbitration_buffer & "00" & can_dlc;

    can_busy <= can_busy_out;

    set_ram_addr: process(state, next_state, reg_cmd, reg_a, reg_b, crc_pdata)
    begin
        if (state = s_idle or state = s_can_transmitting) then
            if (reg_cmd = "1100") then
                ram_addr <= std_logic_vector("0" & reg_b);
            elsif (reg_cmd = "1101") then
                ram_addr <= std_logic_vector("0" & reg_a);
            else
                ram_addr <= (others => '0');
            end if;
        elsif (state = s_can_buffering) then
            ram_addr <= std_logic_vector(crc_pdata);
        elsif (state = s_crc_busy or next_state = s_can_crc_busy) then
            ram_addr <= std_logic_vector(crc_pdata + 1);
        else
            ram_addr <= (others => '0');
        end if;
    end process;

    set_ram_write: process(state, reg_cmd, reg_a)
    begin
        if ((state = s_idle or state = s_can_transmitting) and reg_cmd = "1100") then
            ram_we <= '1';
            ram_di <= std_logic_vector(reg_a);
        else 
            ram_we <= '0';
            ram_di <= (others => '0');
        end if;
    end process;

    set_result : process(state, reg_cmd, a_exp, b_exp, reg_a, reg_b, crc_out)
    begin
        if ((state = s_crc_busy or state = s_can_crc_busy) and crc_done) then
            result <= signed(resize(unsigned(crc_out), 16));
        elsif (state = s_can_buffering) then
            -- TODO: check if we can use this time to do something else
            result <= (others => '0');
        else
            -- we are in s_idle or s_can_transmitting state
            -- CRC output won't conflict with the result buffer
            -- so we can use the result buffer for other operations
            case reg_cmd is
                when "0000" => -- flow = a + b
                    result <= a_exp + b_exp;
                when "0001" => -- flow = a - b
                    result <= a_exp - b_exp;
                when "0010" => -- flow = (a + b) * 2
                    result <= (a_exp + b_exp) sll 1; -- 16 bit OP & assuming big endian
                when "0011" => -- flow = (a + b) * 4
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

    set_cout : process(reg_cmd, result, reg_a, reg_b)
    begin
        -- set carry bit for signed 8 bit addition/subtraction
        if (reg_cmd = "0000" and result > 127) or (reg_cmd = "0001" and unsigned(reg_a) < unsigned(reg_b)) then
            cout <= '1';
        elsif (reg_cmd = "0100" and result(7) = '1') then
            cout <= '1';
        elsif (reg_cmd = "0101" and result > 127) then
            cout <= '1';
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
        variable less_than_0 : boolean;
    begin
        if (reg_cmd = "0010" or reg_cmd = "0011" or reg_cmd = "1001") then
            -- 16 bit ops
            less_than_0 := result < 0;
        else 
            -- 8 bit ops
            less_than_0 := result(7) = '1';
        end if;
        -- set sign bit
        if (less_than_0) then
            sign <= '1';
        else
            sign <= '0';
        end if;
    end process;

end alu_beh;

