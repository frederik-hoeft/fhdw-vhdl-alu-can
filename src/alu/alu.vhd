library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library unisim;
use unisim.vcomponents.all;

entity alu is
    port (clk : in std_logic);
    a, b : in std_logic_vector(7 downto 0);
    cmd : in std_logic_vector(3 downto 0);
    flow : out std_logic_vector(7 downto 0);
    fhigh : out std_logic_vector(7 downto 0);
    cout, equal, ov, sign, cb, ready, can : out std_logic;
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

    -- 9 bit Address Bus for RAM
    signal ram_addr : std_logic_vector(8 downto 0);

    -- RAM control signals
    signal ram_we : std_logic;
    signal ram_di, ram_do : std_logic_vector(7 downto 0);

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
    signal reg_cmd : std_logic_vector(3 downto 0);

    signal can_reg : std_logic_vector(18 downto 0);

    -- registers for storing the input values
    signal reg_a, reg_b : integer range -128 to 127;

    -- signal for expanding the 8 bit input values to 16 bit
    signal a_exp, b_exp : integer range -32768 to 32767;

    -- signal for storing the output values (signed 16 bit)
    signal result : integer range -32768 to 32767;

    signal busy : std_logic;
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
    
    -- process for storing the command and the input values
    -- basically the "state machine"
    snap_inputs : process(clk) is
    begin
        if rising_edge(clk) and busy = '0' then
            reg_cmd <= cmd;
            reg_a <= to_integer(signed(a));
            reg_b <= to_integer(signed(b));
        end if;
    end process;

    a_exp <= resize(reg_a, 16);
    b_exp <= resize(reg_b, 16);

    -- process for calculating the result
    calc_result : process(reg_cmd, a_exp, b_exp, reg_a) is
    begin
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
                result <= a_exp * b_exp;
            when "1010" => -- flow = ~(a & b) (bitwise nand)
                result <= not (a_exp and b_exp);
            when "1011" => -- flow = a ^ b (bitwise xor)
                result <= a_exp xor b_exp;
            when "1100" => -- RAM [b] = a
                ram_addr <= std_logic_vector(to_unsigned(reg_b, 9));
                ram_we <= '1';
                ram_di <= std_logic_vector(to_unsigned(reg_a, 8));
                result <= reg_a;
            when "1101" => -- flow = CRC RAM [a..b]
                result <= 0; -- TODO
            when "1110" => -- can = can_reg concat RAM [a..b] (serial)
                result <= 0; -- TODO
            when others => -- RESERVED
                result <= 0;
                report "RESERVED" severity error;
        end case;
    end process;

    -- output flag processing
    set_equal : process(a_exp, b_exp) is
    begin
        if a_exp = b_exp then
            equal <= '1';
        else
            equal <= '0';
        end if;
    end process;

    set_cout : process(reg_cmd, result, a_exp, b_exp) is
    begin
        -- set carry bit for signed 8 bit addition/subtraction
        if reg_cmd = "0000" and result > 127 or reg_cmd = "0001" and to_unsigned(reg_a) < to_unsigned(reg_b) then
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

    -- process for setting the output values
    set_outputs : process(result) is
    begin
        flow <= std_logic_vector(to_unsigned(result(7 downto 0), 8));
        fhigh <= std_logic_vector(to_unsigned(result(15 downto 8), 8));
        cb <= '0';
        ready <= '0';
        can <= '0';
    end process;

end alu_beh;

