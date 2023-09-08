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
    -- up to 64 bits data
    -- (15 bits tx_crc stored separately)
    -- ACK, IFS, etc via state machine
    constant TX_BUFFER_MAX : integer := 82;

    signal tx_buffer : std_logic_vector(TX_BUFFER_MAX downto 0);

    -- the buffer size counter is 0 when the buffer is full
    constant TX_BUFFER_SIZE_COUNTER_MAX : integer := 11;
    signal tx_buffer_size_counter, tx_buffer_size_counter_next : unsigned(3 downto 0) := to_unsigned(TX_BUFFER_SIZE_COUNTER_MAX, 4);
    signal tx_end_of_data : std_logic_vector(6 downto 0);

    signal tx_buffer_10, tx_buffer_10_next : std_logic_vector(2 downto 0);

    signal tx_buffer_9, tx_buffer_8, tx_buffer_7, tx_buffer_6, tx_buffer_5, 
           tx_buffer_4, tx_buffer_3, tx_buffer_2, tx_buffer_1, tx_buffer_0 : std_logic_vector(7 downto 0);
        
    signal tx_buffer_9_next, tx_buffer_8_next, tx_buffer_7_next, tx_buffer_6_next, tx_buffer_5_next, 
           tx_buffer_4_next, tx_buffer_3_next, tx_buffer_2_next, tx_buffer_1_next, tx_buffer_0_next : std_logic_vector(7 downto 0);

    -- the data bit pointer points to the next bit to be transmitted
    -- also starting at the top of the buffer, and going down
    signal tx_bit_pointer : integer range TX_BUFFER_MAX downto 0 := 0;
    signal tx_bit_pointer_next : integer range TX_BUFFER_MAX downto 0 := 0;

    constant TX_CRC_BUFFER_MAX : integer := 14;

    signal tx_crc_buffer, tx_crc_buffer_next : std_logic_vector(TX_CRC_BUFFER_MAX downto 0);

    -- the tx_crc bit pointer points to the next CRC bit to be transmitted
    -- to ensure network order, the CRC is transmitted MSB first (pointer goes down)
    signal tx_crc_bit_pointer : integer range TX_CRC_BUFFER_MAX downto 0 := 0;
    signal tx_crc_bit_pointer_next : integer range TX_CRC_BUFFER_MAX downto 0 := 0;

    signal state : state_type := idle;
    signal next_state : state_type := idle;

    -- bit stuffing
    -- the CAN bus requires that no more than 5 consecutive bits of the same value are transmitted
    -- we count the number of consecutive bits of the same value that we have transmitted
    -- so if we reach 4, the next bit is the inverse of the previous bit
    signal stuffing_counter : integer range 0 to 4 := 0;
    signal stuffing_counter_next : integer range 0 to 4 := 0;
    -- the stuffing bit is the bit that we are counting, NOT the bit that will be inserted
    -- so if the stuffing_bit is 0, then the previous bit was also 0. In case of stuffing, the inserted will be 1
    signal stuffing_bit : std_logic := '0';
    signal stuffing_bit_next : std_logic := '0';
begin
    
    refresh_state : process(clk, reset)
    begin
        if (rising_edge(clk)) then
            if (reset = '1') then
                state <= idle;
                tx_crc_buffer <= (others => '0');
                tx_bit_pointer <= TX_BUFFER_MAX;
                tx_crc_bit_pointer <= TX_CRC_BUFFER_MAX;
                stuffing_counter <= 0;
                stuffing_bit <= '1';
                tx_buffer_size_counter <= to_unsigned(TX_BUFFER_SIZE_COUNTER_MAX, 4);
                tx_buffer_10 <= (others => '0');
                tx_buffer_9 <= (others => '0');
                tx_buffer_8 <= (others => '0');
                tx_buffer_7 <= (others => '0');
                tx_buffer_6 <= (others => '0');
                tx_buffer_5 <= (others => '0');
                tx_buffer_4 <= (others => '0');
                tx_buffer_3 <= (others => '0');
                tx_buffer_2 <= (others => '0');
                tx_buffer_1 <= (others => '0');
                tx_buffer_0 <= (others => '0');
            else
                state <= next_state;
                tx_crc_buffer <= tx_crc_buffer_next;
                tx_bit_pointer <= tx_bit_pointer_next;
                tx_crc_bit_pointer <= tx_crc_bit_pointer_next;
                stuffing_counter <= stuffing_counter_next;
                stuffing_bit <= stuffing_bit_next;
                tx_buffer_size_counter <= tx_buffer_size_counter_next;
                tx_buffer_10 <= tx_buffer_10_next;
                tx_buffer_9 <= tx_buffer_9_next;
                tx_buffer_8 <= tx_buffer_8_next;
                tx_buffer_7 <= tx_buffer_7_next;
                tx_buffer_6 <= tx_buffer_6_next;
                tx_buffer_5 <= tx_buffer_5_next;
                tx_buffer_4 <= tx_buffer_4_next;
                tx_buffer_3 <= tx_buffer_3_next;
                tx_buffer_2 <= tx_buffer_2_next;
                tx_buffer_1 <= tx_buffer_1_next;
                tx_buffer_0 <= tx_buffer_0_next;
            end if;
        end if;
    end process refresh_state;

    tx_end_of_data <= std_logic_vector(tx_buffer_size_counter) & "000";
    tx_buffer <= tx_buffer_10 & tx_buffer_9 & tx_buffer_8 & tx_buffer_7 & tx_buffer_6 
                & tx_buffer_5 & tx_buffer_4 & tx_buffer_3 & tx_buffer_2 & tx_buffer_1 & tx_buffer_0;

    transition : process(state, buffer_strobe, tx_bit_pointer, tx_crc_bit_pointer)
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
                -- if we are at the end of the buffer, go to tx_crc
                if (std_logic_vector(to_unsigned(tx_bit_pointer, tx_end_of_data'length)) = tx_end_of_data) then
                    next_state <= tx_crc;
                else
                    next_state <= tx_data;
                end if;
            when tx_crc =>
                if (tx_crc_bit_pointer = 0) then
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

    set_next_tx_buffer_size_counter : process(state, tx_buffer_size_counter, buffer_strobe)
    begin
        if (buffer_strobe = '1') then
            -- if the buffer strobe is active, decrement the buffer size counter
            -- we trust the user to not send more data than the buffer can hold
            tx_buffer_size_counter_next <= tx_buffer_size_counter - 1;
        elsif (state = idle) then
            -- if we are idling, reset the buffer size counter
            tx_buffer_size_counter_next <= to_unsigned(TX_BUFFER_SIZE_COUNTER_MAX, 4);
        else
            -- otherwise, hold the current value
            tx_buffer_size_counter_next <= tx_buffer_size_counter;
        end if;
    end process set_next_tx_buffer_size_counter;

    -- update the tx buffers
    set_next_tx_buffer_10 : process(tx_buffer_10, tx_buffer_size_counter, parallel_in, buffer_strobe)
    begin
        if (buffer_strobe = '1' and tx_buffer_size_counter = 11) then
            tx_buffer_10_next <= parallel_in(2 downto 0);
        else
            tx_buffer_10_next <= tx_buffer_10;
        end if;
    end process set_next_tx_buffer_10;

    set_next_tx_buffer_9 : process(tx_buffer_9, tx_buffer_size_counter, parallel_in, buffer_strobe)
    begin
        if (buffer_strobe = '1' and tx_buffer_size_counter = 10) then
            tx_buffer_9_next <= parallel_in;
        else
            tx_buffer_9_next <= tx_buffer_9;
        end if;
    end process set_next_tx_buffer_9;

    set_next_tx_buffer_8 : process(tx_buffer_8, tx_buffer_size_counter, parallel_in, buffer_strobe)
    begin
        if (buffer_strobe = '1' and tx_buffer_size_counter = 9) then
            tx_buffer_8_next <= parallel_in;
        else
            tx_buffer_8_next <= tx_buffer_8;
        end if;
    end process set_next_tx_buffer_8;

    set_next_tx_buffer_7 : process(tx_buffer_7, tx_buffer_size_counter, parallel_in, buffer_strobe)
    begin
        if (buffer_strobe = '1' and tx_buffer_size_counter = 8) then
            tx_buffer_7_next <= parallel_in;
        else
            tx_buffer_7_next <= tx_buffer_7;
        end if;
    end process set_next_tx_buffer_7;

    set_next_tx_buffer_6 : process(tx_buffer_6, tx_buffer_size_counter, parallel_in, buffer_strobe)
    begin
        if (buffer_strobe = '1' and tx_buffer_size_counter = 7) then
            tx_buffer_6_next <= parallel_in;
        else
            tx_buffer_6_next <= tx_buffer_6;
        end if;
    end process set_next_tx_buffer_6;

    set_next_tx_buffer_5 : process(tx_buffer_5, tx_buffer_size_counter, parallel_in, buffer_strobe)
    begin
        if (buffer_strobe = '1' and tx_buffer_size_counter = 6) then
            tx_buffer_5_next <= parallel_in;
        else
            tx_buffer_5_next <= tx_buffer_5;
        end if;
    end process set_next_tx_buffer_5;

    set_next_tx_buffer_4 : process(tx_buffer_4, tx_buffer_size_counter, parallel_in, buffer_strobe)
    begin
        if (buffer_strobe = '1' and tx_buffer_size_counter = 5) then
            tx_buffer_4_next <= parallel_in;
        else
            tx_buffer_4_next <= tx_buffer_4;
        end if;
    end process set_next_tx_buffer_4;

    set_next_tx_buffer_3 : process(tx_buffer_3, tx_buffer_size_counter, parallel_in, buffer_strobe)
    begin
        if (buffer_strobe = '1' and tx_buffer_size_counter = 4) then
            tx_buffer_3_next <= parallel_in;
        else
            tx_buffer_3_next <= tx_buffer_3;
        end if;
    end process set_next_tx_buffer_3;

    set_next_tx_buffer_2 : process(tx_buffer_2, tx_buffer_size_counter, parallel_in, buffer_strobe)
    begin
        if (buffer_strobe = '1' and tx_buffer_size_counter = 3) then
            tx_buffer_2_next <= parallel_in;
        else
            tx_buffer_2_next <= tx_buffer_2;
        end if;
    end process set_next_tx_buffer_2;

    set_next_tx_buffer_1 : process(tx_buffer_1, tx_buffer_size_counter, parallel_in, buffer_strobe)
    begin
        if (buffer_strobe = '1' and tx_buffer_size_counter = 2) then
            tx_buffer_1_next <= parallel_in;
        else
            tx_buffer_1_next <= tx_buffer_1;
        end if;
    end process set_next_tx_buffer_1;

    set_next_tx_buffer_0 : process(tx_buffer_0, tx_buffer_size_counter, parallel_in, buffer_strobe)
    begin
        if (buffer_strobe = '1' and tx_buffer_size_counter = 1) then
            tx_buffer_0_next <= parallel_in;
        else
            tx_buffer_0_next <= tx_buffer_0;
        end if;
    end process set_next_tx_buffer_0;

    -- update the stuffing bit (the thing that we are counting) and the how often it has been consecutively transmitted
    set_stuffing_params : process(state, stuffing_counter, stuffing_bit, can_out_pre_stuffing)
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

    -- update the transmit bit pointer
    set_next_tx_bit_counter : process(state, tx_bit_pointer, stuffing_counter)
    begin
        if (state = tx_data) then
            if (stuffing_counter = 4) then
                -- if we are stuffing, delay the transmission of the next bit
                tx_bit_pointer_next <= tx_bit_pointer;
            else
                -- otherwise, decrement the pointer
                tx_bit_pointer_next <= tx_bit_pointer - 1;
            end if;
        else
            -- if we are not transmitting data, reset the pointer
            tx_bit_pointer_next <= TX_BUFFER_MAX;
        end if;
    end process set_next_tx_bit_counter;

    -- update the transmit tx_crc bit pointer
    set_next_tx_crc_bit_counter : process(state, tx_crc_bit_pointer, stuffing_counter)
    begin
        if (state = tx_crc) then
            if (stuffing_counter = 4) then
                -- if we are stuffing, delay the transmission of the next bit
                tx_crc_bit_pointer_next <= tx_crc_bit_pointer;
            else
                -- otherwise, decrement the pointer
                tx_crc_bit_pointer_next <= tx_crc_bit_pointer - 1;
            end if;
        else
            -- if we are not transmitting tx_crc, reset the pointer
            tx_crc_bit_pointer_next <= TX_CRC_BUFFER_MAX;
        end if;
    end process set_next_tx_crc_bit_counter;

    -- determine the next thing to transmit, independent of bit stuffing
    set_can_out_pre_stuffing : process(state, tx_buffer, tx_bit_pointer, tx_crc_buffer, tx_crc_bit_pointer)
    begin
        case state is
            when tx_data =>
                can_out_pre_stuffing <= tx_buffer(tx_bit_pointer);
            when tx_crc =>
                can_out_pre_stuffing <= tx_crc_buffer(tx_crc_bit_pointer);
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
        if (state = idle or state = tx_ifs_0) then
            busy <= '0';
        else
            busy <= '1';
        end if;
    end process set_busy;

end behavioral;