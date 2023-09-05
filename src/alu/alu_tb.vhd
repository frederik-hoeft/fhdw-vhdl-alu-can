---------------------------------------------------------------
--                          TestBench
---------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use std.textio.all;
use ieee.numeric_std.all;

entity alu_tb is
end alu_tb;

architecture test_bench of alu_tb is
    -- component declaration for the Unit Under Test (UUT)
    component alu is
        port (clk, reset : in std_logic;
        a, b : in std_logic_vector(7 downto 0);
        cmd : in std_logic_vector(3 downto 0);
        flow, fhigh : out std_logic_vector(7 downto 0);
        cout, equal, ov, sign, cb, ready, can : out std_logic);
    end component;

    -- inputs
    signal clk : std_logic := '1';
    signal a, b : std_logic_vector(7 downto 0) := (others => '0');
    signal cmd : std_logic_vector(3 downto 0) := (others => '0');
    signal reset : std_logic_vector(0 downto 0) := (others => '0');

    signal delayed_a : std_logic_vector(7 downto 0) := (others => '0');
    signal delayed_b : std_logic_vector(7 downto 0) := (others => '0');
    signal delayed_cmd : std_logic_vector(3 downto 0) := (others => '0');
    signal delayed_reset : std_logic_vector(0 downto 0) := (others => '0');

    -- outputs
    signal flow : std_logic_vector(7 downto 0);
    signal fhigh : std_logic_vector(7 downto 0);
    signal cout, equal, ov, sign, cb, ready, can : std_logic_vector(0 downto 0);

    -- simulation
    signal DebugVariable : boolean:=true;
    signal is_first_monitor_call : boolean := true;

    -- monitoring
    shared variable expected_flow : string(8 downto 1);
    shared variable expected_fhigh : string(8 downto 1);
    shared variable expected_cout : string(1 downto 1);
    shared variable expected_equal : string(1 downto 1);
    shared variable expected_ov : string(1 downto 1);
    shared variable expected_sign : string(1 downto 1);
    shared variable expected_cb : string(1 downto 1);
    shared variable expected_ready : string(1 downto 1);
    shared variable expected_can : string(1 downto 1);

    -- (monitoring) line status
    shared variable success : boolean := true;
    -- (monitoring) stop logging after end of file
    shared variable expected_eof : boolean := false;

    -- constants
    constant clock_period : time := 100 ns;
    --=============================================================
    -- functions
    function char2std_logic (ch: in character) return std_logic is
    begin
        case ch is
            when 'U' | 'u' => return 'U';
            when 'X' | 'x' => return 'X';
            when '0' => return '0';
            when '1' => return '1';
            when 'Z' | 'z' => return 'Z';
            when 'W' | 'w' => return 'W';
            when 'L' | 'l' => return 'L';
            when 'H' | 'h' => return 'H';
            when '-' => return '-';
            when others =>
        assert FALSE
            report "Illegal Character found" & ch
            severity error;
        return 'U';
        end case;
    end;

    -- converts a string into a std_logic_vector
    function string2std_logic (s: string) return std_logic_vector is
        variable vector: std_logic_vector(s'LEFT - 1 downto 0);
    begin
        for i in s'range loop
            vector(i-1) := char2std_logic(s(i));
        end loop;
        return vector;
    end;

    -- converts std_logic into a character
    function std_logic2char(sl: std_logic) return character is
        variable c: character;
    begin
        case sl is
            when 'U' => c:= 'U';
            when 'X' => c:= 'X';
            when '0' => c:= '0';
            when '1' => c:= '1';
            when 'Z' => c:= 'Z';
            when 'W' => c:= 'W';
            when 'L' => c:= 'L';
            when 'H' => c:= 'H';
            when '-' => c:= '-';
        end case;
        return c;
    end std_logic2char;

    -- converts a std_logic_vector into a string
    function std_logic2string(slv: std_logic_vector) return string is
        variable result : string (1 to slv'length);
        variable r : integer;
    begin
        r := 1;
        for i in slv'range loop
            result(r) := std_logic2char(slv(i));
            r := r + 1;
        end loop;
        return result;
    end std_logic2string;

    -- asserts that two std_logic_vectors are equal and returns true if they are equal
    -- allows don't care values ('-') in the expected vector
    function assert_equals(expected: std_logic_vector; actual: std_logic_vector; name: string) return boolean is
        variable bit_equals : boolean;
        variable assert_success : boolean;
        variable bit_e : std_logic;
        variable bit_a : std_logic;
    begin
        assert_success := expected'length = actual'length;
        if (assert_success) then
            for i in expected'range loop
                bit_e := expected(i);
                bit_a := actual(i);
                case bit_e is
                    when '-' => bit_equals := true;
                    when others => bit_equals := (bit_e = bit_a);
                end case;
                assert_success := assert_success and bit_equals;
            end loop;
        end if;
        assert assert_success
            report "Assert failed for signal '" & name & "': expected: " & std_logic2string(expected) & ", actual: " & std_logic2string(actual)
            severity warning;
        return assert_success;
    end assert_equals;

-- Testbench
begin
    -- clock generator
    clk <= not clk after clock_period / 2;

    -- Unit Under Test (UUT)
    uut : alu port map (
        clk => clk,
        reset => reset(0),
        a => a,
        b => b,
        cmd => cmd,
        flow => flow,
        fhigh => fhigh,
        cout => cout(0),
        equal => equal(0),
        ov => ov(0),
        sign => sign(0),
        cb => cb(0),
        ready => ready(0),
        can => can(0)
    );

    -- delayed inputs (to allow for consistent logging)
    -- this compensates for the input - output delay
    delay_inputs: process(clk)
    begin
        if (rising_edge(clk)) then
            delayed_a <= a;
            delayed_b <= b;
            delayed_cmd <= cmd;
            delayed_reset <= reset;
        end if;
    end process delay_inputs;

    -- Stimulus process
    STIMULI: process(clk)
        file testpattern: text OPEN READ_MODE is "tb-inputs.txt";
        variable var_line: line;
        variable whitespace: character;
        variable buffer_1: string(1 downto 1);
        variable buffer_4: string(4 downto 1);
        variable buffer_8: string(8 downto 1);
    begin
        assert DebugVariable report "STIMULI" severity note;
        -- start immediately
        if (falling_edge(clk)) then
            if (not endfile(testpattern)) then
                readline(testpattern, var_line);
                -- a
                read(var_line, buffer_8);
                a <= string2std_logic(buffer_8);
                read(var_line, whitespace);
                -- b
                read(var_line, buffer_8);
                b <= string2std_logic(buffer_8);
                read(var_line, whitespace);
                -- cmd
                read(var_line, buffer_4);
                cmd <= string2std_logic(buffer_4);
                read(var_line, whitespace);
                -- reset
                read(var_line, buffer_1);
                reset <= string2std_logic(buffer_1);
            else
                a <= (others => '0');
                b <= (others => '0');
                cmd <= (others => '0');
                reset <= (others => '0');
            end if;
        end if;
    end process STIMULI;

    -- Response process
    RESPONSE: process(clk)
        file comparison_pattern: text OPEN READ_MODE is "tb-expected.txt";
        variable var_line: line;
        variable whitespace: character;
        variable buffer_1: string(1 downto 1);
        variable buffer_4: string(4 downto 1);
        variable buffer_8: string(8 downto 1);
    begin
        assert DebugVariable report "EXPECTED" severity note;
        if(rising_edge(clk)) then
            -- only check after first clock cycle (allow for device to initialize)
            if(now >= clock_period) then
                success := true;
                if(not endfile(comparison_pattern)) then
                    readline(comparison_pattern, var_line);
                    -- flow
                    read(var_line, buffer_8);
                    expected_flow := buffer_8;
                    read(var_line, whitespace);
                    success := success and assert_equals(string2std_logic(expected_flow), flow, "flow");

                    -- fhigh
                    read(var_line, buffer_8);
                    expected_fhigh := buffer_8;
                    read(var_line, whitespace);
                    success := success and assert_equals(string2std_logic(expected_fhigh), fhigh, "fhigh");

                    -- cout
                    read(var_line, buffer_1);
                    expected_cout := buffer_1;
                    read(var_line, whitespace);
                    success := success and assert_equals(string2std_logic(expected_cout), cout, "cout");

                    -- equal
                    read(var_line, buffer_1);
                    expected_equal := buffer_1;
                    read(var_line, whitespace);
                    success := success and assert_equals(string2std_logic(expected_equal), equal, "equal");

                    -- ov
                    read(var_line, buffer_1);
                    expected_ov := buffer_1;
                    read(var_line, whitespace);
                    success := success and assert_equals(string2std_logic(expected_ov), ov, "ov");

                    -- sign
                    read(var_line, buffer_1);
                    expected_sign := buffer_1;
                    read(var_line, whitespace);
                    success := success and assert_equals(string2std_logic(expected_sign), sign, "sign");

                    -- cb
                    read(var_line, buffer_1);
                    expected_cb := buffer_1;
                    read(var_line, whitespace);
                    success := success and assert_equals(string2std_logic(expected_cb), cb, "cb");

                    -- ready
                    read(var_line, buffer_1);
                    expected_ready := buffer_1;
                    read(var_line, whitespace);
                    success := success and assert_equals(string2std_logic(expected_ready), ready, "ready");

                    -- can
                    read(var_line, buffer_1);
                    expected_can := buffer_1;
                    read(var_line, whitespace);
                    success := success and assert_equals(string2std_logic(expected_can), can, "can");
                else 
                    expected_eof := true;
                    expected_flow := (others => '-');
                    expected_fhigh := (others => '-');
                    expected_cout := (others => '-');
                    expected_equal := (others => '-');
                    expected_ov := (others => '-');
                    expected_sign := (others => '-');
                    expected_cb := (others => '-');
                    expected_ready := (others => '-');
                    expected_can := (others => '-');
                end if;
            end if;
        end if;
    end process RESPONSE;

    -- Monitor process
    MONITOR: process(clk)
        file protocol: text OPEN WRITE_MODE is "tb-log.csv";
        variable var_line: line;
        variable separator: character := ',';
        variable v_a: string(8 downto 1);
        variable v_b: string(8 downto 1);
        variable v_cmd: string(4 downto 1);
        variable v_reset: string(1 downto 1);
        variable v_flow: string(8 downto 1);
        variable v_fhigh: string(8 downto 1);
        variable v_cout: string(1 downto 1);
        variable v_equal: string(1 downto 1);
        variable v_ov: string(1 downto 1);
        variable v_sign: string(1 downto 1);
        variable v_cb: string(1 downto 1);
        variable v_ready: string(1 downto 1);
        variable v_can: string(1 downto 1);
        variable v_status: string(7 downto 1);
        variable simulation_time: time;
    begin
        assert DebugVariable report "MONITOR" severity note;
        -- write CSV header (obviously only once)
        if (is_first_monitor_call) then
            is_first_monitor_call <= false;
            write(var_line, "<STATUS> at <TIME> (@");
            write(var_line, clock_period);
            write(var_line, "),,a,b,cmd,reset,,flow(exp:act),fhigh(exp:act),cout(exp:act),equal(exp:act),ov(exp:act),sign(exp:act),cb(exp:act),ready(exp:act),can(exp:act)");
            writeline(protocol, var_line);
        end if;
        -- only log after first two clock cycles (one to allow for device to initialize
        -- and the other one because input to output takes a cycle, so there won't be valid
        -- data immediately)
        if(now >= 2 * clock_period and not expected_eof) then
            if(rising_edge(clk)) then
                v_a := std_logic2string(delayed_a);
                v_b := std_logic2string(delayed_b);
                v_cmd := std_logic2string(delayed_cmd);
                v_reset := std_logic2string(delayed_reset);
                v_flow := std_logic2string(flow);
                v_fhigh := std_logic2string(fhigh);
                v_cout := std_logic2string(cout);
                v_equal := std_logic2string(equal);
                v_ov := std_logic2string(ov);
                v_sign := std_logic2string(sign);
                v_cb := std_logic2string(cb);
                v_ready := std_logic2string(ready);
                v_can := std_logic2string(can);
                if (success) then
                    v_status := "SUCCESS";
                else
                    v_status := "FAILURE";
                end if;
                simulation_time := now;
                write(var_line, v_status & " at ");
                write(var_line, simulation_time);
                write(var_line, separator);
                write(var_line, separator);
                write(var_line, v_a);
                write(var_line, separator);
                write(var_line, v_b);
                write(var_line, separator);
                write(var_line, v_cmd);
                write(var_line, separator);
                write(var_line, v_reset);
                write(var_line, separator);
                write(var_line, separator);
                write(var_line, expected_flow & ":" & v_flow);
                write(var_line, separator);
                write(var_line, expected_fhigh & ":" & v_fhigh);
                write(var_line, separator);
                write(var_line, expected_cout & ":" & v_cout);
                write(var_line, separator);
                write(var_line, expected_equal & ":" & v_equal);
                write(var_line, separator);
                write(var_line, expected_ov & ":" & v_ov);
                write(var_line, separator);
                write(var_line, expected_sign & ":" & v_sign);
                write(var_line, separator);
                write(var_line, expected_cb & ":" & v_cb);
                write(var_line, separator);
                write(var_line, expected_ready & ":" & v_ready);
                write(var_line, separator);
                write(var_line, expected_can & ":" & v_can);
                writeline(protocol, var_line);
            end if;
        end if;     
    end process MONITOR;
end test_bench;