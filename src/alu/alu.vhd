library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library unisim;
use unisim.vcomponents.all;

entity alu is
    port (clk, reset : in std_logic;
    a, b : in std_logic_vector(7 downto 0);
    cmd : in std_logic_vector(3 downto 0);
    flow : out std_logic_vector(7 downto 0);
    fhigh : out std_logic_vector(7 downto 0);
    cout, equal, ov, sign, cb, ready, can : out std_logic);
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

    type state_type is (idle, crc_busy, can_busy);

    signal state : state_type := idle;
    signal next_state : state_type := idle;

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

    signal reg_can : std_logic_vector(18 downto 0) := (others => '0');

    -- registers for storing the input values
    signal reg_a, reg_b : signed(7 downto 0) := (others => '0');

    -- signal for expanding the 8 bit input values to 16 bit
    signal a_exp, b_exp : signed(15 downto 0) := (others => '0');

    signal crc_current, crc_next, crc_out : std_logic_vector(14 downto 0) := (others => '0');
    signal crc_pdata, crc_pnext : unsigned(8 downto 0) := (others => '0');
    signal crc_pend, crc_pend_next : unsigned(7 downto 0) := (others => '0');

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

    -- process for storing the command and the input values
    snap_inputs : process(clk, state) is
    begin
        if rising_edge(clk) then
            reg_cmd <= cmd;
            reg_a <= signed(a);
            reg_b <= signed(b);
        end if;
    end process;

    a_exp <= resize(reg_a, 16);
    b_exp <= resize(reg_b, 16);

    refresh_state : process(clk, reset) is
    begin
        if (rising_edge(clk)) then
            if (reset = '1') then
                state <= idle;
                crc_pdata <= (others => '0');
                crc_current <= (others => '0');
                crc_pend <= (others => '0');
            else
                state <= next_state;
                crc_pdata <= crc_pnext;
                crc_current <= crc_next;
                crc_pend <= crc_pend_next;
            end if;
        end if;
    end process;

    -- process for calculating the next state
    transition : process(state, reg_cmd, crc_pdata, crc_pend) is
    begin
        case state is
            when idle =>
                case reg_cmd is
                    when "1101" =>
                        next_state <= crc_busy;
                    when "1110" =>
                        next_state <= can_busy;
                    when others =>
                        next_state <= idle;
                end case;
            when crc_busy =>
                if (crc_pdata > crc_pend) then
                    next_state <= idle;
                else
                    next_state <= crc_busy;
                end if;
            when can_busy =>
                -- TODO: implement CAN protocol
                next_state <= can_busy;
            when others =>
                report "UNKNOWN STATE" severity error;
                next_state <= idle;
        end case;
    end process transition;

    crc_transition: process(state, reg_cmd, crc_pdata, reg_b) is
    begin
        if (state = idle and reg_cmd = "1101") then
            crc_pnext <= resize(unsigned(reg_b), 9);
        elsif (state = crc_busy) then
            crc_pnext <= crc_pdata + 1;
        else
            crc_pnext <= (others => '0');
        end if;
    end process;

    set_crc_params : process(state, reg_cmd, crc_out, reg_b, crc_pend, crc_current) is
    begin
        if (state = idle and reg_cmd = "1101") then
            crc_next <= (others => '1'); -- reset CRC IV
            crc_pend_next <= unsigned(reg_b);
        elsif (state = crc_busy) then
            crc_next <= crc_out;
            crc_pend_next <= crc_pend;
        else
            crc_next <= crc_current;
            crc_pend_next <= crc_pend;
        end if;
    end process;

    set_crc_busy : process(state, reg_cmd) is
    begin
        if (state = crc_busy or (state = idle and reg_cmd = "1101")) then
            cb <= '1';
        else
            cb <= '0';
        end if;
    end process;

    -- TODO: implement CAN protocol
    set_ready : process(state) is
    begin
        if (state = idle) then
            ready <= '0';
        else
            ready <= '1';
        end if;
    end process;

    can <= '0'; -- TODO: implement CAN protocol

    set_ram_addr: process(state, reg_cmd, reg_a, reg_b, crc_pdata) is
    begin
        if (state = idle) then
            if (reg_cmd = "1100") then
                ram_addr <= std_logic_vector("0" & reg_b);
            elsif (reg_cmd = "1101") then
                ram_addr <= std_logic_vector("0" & reg_a);
            else
                ram_addr <= (others => '0');
            end if;
        elsif (state = crc_busy) then
            ram_addr <= std_logic_vector(crc_pdata + 1);
        else
            ram_addr <= (others => '0');
        end if;
    end process;

    set_ram_write: process(state, reg_cmd, reg_a) is
    begin
        if (state = idle and reg_cmd = "1100") then
            ram_we <= '1';
            ram_di <= std_logic_vector(reg_a);
        else 
            ram_we <= '0';
            ram_di <= (others => '0');
        end if;
    end process;

    set_result : process(state, reg_cmd, a_exp, b_exp, reg_a, reg_b, crc_out) is
    begin
        case state is
            when idle =>
                case reg_cmd is
                    when "0000" => -- flow = a + b
                        result <= a_exp + b_exp;
                    when "0001" => -- flow = a - b
                        result <= a_exp - b_exp;
                    when "0010" => -- flow = (a + b) * 2
                        result <= (a_exp + b_exp) sll 1; -- assuming big endian
                    when "0011" => -- flow = (a + b) * 4
                        result <= (a_exp + b_exp) sll 2; -- assuming big endian
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
            when crc_busy =>
                result <= signed(resize(unsigned(crc_out), 16));
            when can_busy =>
                result <= (others => '0');
            when others =>
                report "UNKNOWN STATE" severity error;
                result <= (others => '0');
        end case;
    end process set_result;

    flow <= std_logic_vector(result(7 downto 0));
    fhigh <= std_logic_vector(result(15 downto 8));

    -- output flag processing
    set_equal : process(a_exp, b_exp) is
    begin
        if a_exp = b_exp then
            equal <= '1';
        else
            equal <= '0';
        end if;
    end process;

    set_cout : process(reg_cmd, result, reg_a, reg_b) is
    begin
        -- set carry bit for signed 8 bit addition/subtraction
        if (reg_cmd = "0000" and result > 127) or (reg_cmd = "0001" and unsigned(reg_a) < unsigned(reg_b)) then
            cout <= '1';
        else
            cout <= '0';
        end if;
    end process;

    set_ov : process(reg_cmd, result) is
    begin
        -- set overflow bit for signed 8 bit addition/subtraction
        if reg_cmd = "000-" and (result > 127 or result < -128) then
            ov <= '1';
        else
            ov <= '0';
        end if;
    end process;

    set_sign : process(result) is
    begin
        -- set sign bit for signed 16 bit result
        if result < 0 then
            sign <= '1';
        else
            sign <= '0';
        end if;
    end process;

end alu_beh;

