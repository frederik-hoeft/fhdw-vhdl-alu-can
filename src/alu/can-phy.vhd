library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity can_phy is port(
    clk, buffer_strobe, crc_strobe, reset : in std_logic;
    crc_in : in std_logic_vector(14 downto 0);
    parallel_in : in std_logic_vector(7 downto 0);
    serial_out : out std_logic;
    busy : out std_logic);
end can_phy;

architecture behavioral of can_phy is
    
    type state_type is (
        idle,
        buffering, 
        tx_data, 
        tx_crc,
        tx_crc_delimiter,
        tx_ack,
        tx_ack_delimiter,
        tx_eof_6, tx_eof_5, tx_eof_4, tx_eof_3, tx_eof_2, tx_eof_1, tx_eof_0,
        tx_ifs_2, tx_ifs_1, tx_ifs_0);

    signal can_out : std_logic;
    signal can_out_pre_stuffing : std_logic;

    -- 83 bit tx buffer:
    -- 19 bits header
    -- 64 bits data
    -- (15 bits tx_crc stored separately)
    -- spacing etc via state machine
    signal tx_buffer : std_logic_vector(82 downto 0);
    signal tx_buffer_next : std_logic_vector(82 downto 0);
    signal tx_buffer_ptr : integer range 0 to 82 := 0;
    signal tx_buffer_ptr_next : integer range 0 to 82 := 0;

    signal tx_bit_counter : integer range 0 to 82 := 0;
    signal tx_bit_counter_next : integer range 0 to 82 := 0;

    signal tx_crc_buffer, tx_crc_buffer_next : std_logic_vector(14 downto 0);
    signal tx_crc_bit_counter : integer range 0 to 14 := 0;
    signal tx_crc_bit_counter_next : integer range 0 to 14 := 0;

    signal state : state_type := idle;
    signal next_state : state_type := idle;

    signal stuffing_counter : integer range 0 to 4 := 0;
    signal stuffing_counter_next : integer range 0 to 4 := 0;
    signal stuffing_bit : std_logic := '0';
    signal stuffing_bit_next : std_logic := '0';
begin
    
    refresh_state : process(clk, reset)
    begin
        if (rising_edge(clk)) then
            if (reset = '1') then
                state <= idle;
                tx_crc_buffer <= (others => '0');
                tx_buffer <= (others => '0');
                tx_buffer_ptr <= 0;
                tx_bit_counter <= 0;
                tx_crc_bit_counter <= 0;
                stuffing_counter <= 0;
                stuffing_bit <= '0';
            else
                state <= next_state;
                tx_crc_buffer <= tx_crc_buffer_next;
                tx_buffer <= tx_buffer_next;
                tx_buffer_ptr <= tx_buffer_ptr_next;
                tx_bit_counter <= tx_bit_counter_next;
                tx_crc_bit_counter <= tx_crc_bit_counter_next;
                stuffing_counter <= stuffing_counter_next;
                stuffing_bit <= stuffing_bit_next;
            end if;
        end if;
    end process refresh_state;

    transition : process(state, buffer_strobe, tx_buffer_ptr, tx_bit_counter, tx_crc_bit_counter)
    begin
        case state is
            when idle =>
                if (buffer_strobe = '1') then
                    next_state <= buffering;
                else
                    next_state <= idle;
                end if;
            when buffering =>
                if (buffer_strobe = '1') then
                    next_state <= buffering;
                else
                    next_state <= tx_data;
                end if;
            when tx_data =>
                if (tx_bit_counter = 82 or tx_bit_counter = tx_buffer_ptr) then
                    next_state <= tx_crc;
                else
                    next_state <= tx_data;
                end if;
            when tx_crc =>
                if (tx_crc_bit_counter = 14) then
                    next_state <= tx_crc_delimiter;
                else
                    next_state <= tx_crc;
                end if;
            when tx_crc_delimiter =>
                next_state <= tx_ack;
            when tx_ack =>
                next_state <= tx_ack_delimiter;
            when tx_ack_delimiter =>
                next_state <= tx_eof_6;
            when tx_eof_6 =>
                next_state <= tx_eof_5;
            when tx_eof_5 =>
                next_state <= tx_eof_4;
            when tx_eof_4 =>
                next_state <= tx_eof_3;
            when tx_eof_3 =>
                next_state <= tx_eof_2;
            when tx_eof_2 =>
                next_state <= tx_eof_1;
            when tx_eof_1 =>
                next_state <= tx_eof_0;
            when tx_eof_0 =>
                next_state <= tx_ifs_2;
            when tx_ifs_2 =>
                next_state <= tx_ifs_1;
            when tx_ifs_1 =>
                next_state <= tx_ifs_0;
            when tx_ifs_0 =>
                next_state <= idle;
            when others =>
                report "CAN PHY: transition from invalid state" severity error;
                next_state <= idle;
        end case;
    end process transition;

    set_next_crc : process(state, crc_in, crc_strobe, tx_crc_buffer)
    begin
        if (state = idle) then
            tx_crc_buffer_next <= (others => '0');
        elsif (crc_strobe = '1') then
            tx_crc_buffer_next <= crc_in;
        else
            tx_crc_buffer_next <= tx_crc_buffer;
        end if;
    end process set_next_crc;

    -- update the buffer pointer where the next word will be written to
    set_next_tx_buffer_ptr : process(state, tx_buffer_ptr, buffer_strobe)
    begin
        if (state = idle and buffer_strobe = '1') then
            -- header is 19 bits, word size is 8 bits
            -- so the first word contains only 3 bits of actual data
            tx_buffer_ptr_next <= 3;
        elsif (buffer_strobe = '1') then
            -- after the first word, the buffer pointer is incremented by full words
            tx_buffer_ptr_next <= tx_buffer_ptr + 8;
        elsif (state = idle) then
            -- if the buffer strobe is not active, and we are idling, the buffer pointer is 0
            tx_buffer_ptr_next <= 0;
        else
            -- otherwise, hold the current value
            tx_buffer_ptr_next <= tx_buffer_ptr;
        end if;
    end process set_next_tx_buffer_ptr;

    -- update the buffer and write new data
    set_next_tx_buffer : process(state, tx_buffer, tx_buffer_ptr, parallel_in, buffer_strobe)
        variable tx_buffer_tmp : std_logic_vector(82 downto 0);
    begin
        tx_buffer_tmp := tx_buffer;
        if (buffer_strobe = '1') then
            if (tx_buffer_ptr = 0) then
                -- first word, only 3 bits of data
                tx_buffer_tmp(2 downto 0) := parallel_in(2 downto 0);
            else
                -- after the first word, write the full 8 bits
                tx_buffer_tmp(tx_buffer_ptr + 7 downto tx_buffer_ptr) := parallel_in;
            end if;
        end if;
        tx_buffer_next <= tx_buffer_tmp;
    end process set_next_tx_buffer;

    -- update the stuffing bit (the thing that we are counting) and the how often it has been consecutively transmitted
    set_stuffing_params : process(state, stuffing_counter, stuffing_bit, tx_bit_counter, can_out_pre_stuffing)
    begin
        if (state = tx_data or state = tx_crc) then
            if (stuffing_bit = can_out_pre_stuffing and stuffing_counter < 4) then
                stuffing_counter_next <= stuffing_counter + 1;
                stuffing_bit_next <= stuffing_bit;
            else
                stuffing_counter_next <= 0;
                stuffing_bit_next <= not stuffing_bit;
            end if;
        else
            stuffing_counter_next <= 0;
            stuffing_bit_next <= '1';
        end if;
    end process set_stuffing_params;

    -- update the transmit bit counter
    set_next_tx_bit_counter : process(state, tx_bit_counter, stuffing_counter)
    begin
        if (state = tx_data) then
            if (stuffing_counter = 4) then
                -- if we are stuffing, delay the transmission of the next bit
                tx_bit_counter_next <= tx_bit_counter;
            elsif (tx_bit_counter < 82) then
                -- otherwise, increment the counter if we are not at the end of the buffer
                tx_bit_counter_next <= tx_bit_counter + 1;
            else
                -- if we are at the end of the buffer, reset the counter
                tx_bit_counter_next <= 0;
            end if;
        else
            -- if we are not transmitting data, reset the counter
            tx_bit_counter_next <= 0;
        end if;
    end process set_next_tx_bit_counter;

    -- update the transmit tx_crc bit counter
    set_next_tx_crc_bit_counter : process(state, tx_crc_bit_counter, stuffing_counter)
    begin
        if (state = tx_crc) then
            if (stuffing_counter = 4) then
                -- if we are stuffing, delay the transmission of the next bit
                tx_crc_bit_counter_next <= tx_crc_bit_counter;
            elsif (tx_crc_bit_counter < 14) then
                -- otherwise, increment the counter if we are not at the end of the tx_crc
                tx_crc_bit_counter_next <= tx_crc_bit_counter + 1;
            else
                -- if we are at the end of the tx_crc, reset the counter
                tx_crc_bit_counter_next <= 0;
            end if;
        else
            -- if we are not transmitting tx_crc, reset the counter
            tx_crc_bit_counter_next <= 0;
        end if;
    end process set_next_tx_crc_bit_counter;

    -- determine the next thing to transmit, independent of bit stuffing
    set_can_out_pre_stuffing : process(state, tx_buffer, tx_bit_counter, tx_crc_buffer, tx_crc_bit_counter)
    begin
        case state is
            when tx_data =>
                can_out_pre_stuffing <= tx_buffer(tx_bit_counter);
            when tx_crc =>
                can_out_pre_stuffing <= tx_crc_buffer(tx_crc_bit_counter);
            when tx_crc_delimiter =>
                can_out_pre_stuffing <= '1';
            when tx_ack =>
                can_out_pre_stuffing <= '0';
            when tx_ack_delimiter =>
                can_out_pre_stuffing <= '1';
            when tx_eof_6 | tx_eof_5 | tx_eof_4 | tx_eof_3 | tx_eof_2 | tx_eof_1 | tx_eof_0 =>
                can_out_pre_stuffing <= '1';
            when tx_ifs_2 | tx_ifs_1 | tx_ifs_0 =>
                can_out_pre_stuffing <= '1';
            when others =>
                can_out_pre_stuffing <= '1';
        end case;
    end process set_can_out_pre_stuffing;

    -- determine the next thing to transmit, including bit stuffing
    apply_stuffing : process(state, stuffing_counter, stuffing_bit, can_out_pre_stuffing)
    begin 
        if ((state = tx_data or state = tx_crc) and stuffing_counter = 4) then
            -- the stuffing bit is the thing that we are counting
            -- if we are stuffing, transmit the inverse of the stuffing bit
            can_out <= not stuffing_bit;
        else
            -- otherwise, transmit whatever we are supposed to transmit
            can_out <= can_out_pre_stuffing;
        end if;
    end process apply_stuffing;

    --------------------------------------------------------------------------------
    -- output signals
    --------------------------------------------------------------------------------
    serial_out <= can_out;

    set_busy : process(state)
    begin
        if (state = idle) then
            busy <= '0';
        else
            busy <= '1';
        end if;
    end process set_busy;

end behavioral;