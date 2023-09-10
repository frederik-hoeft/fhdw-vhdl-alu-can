library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity can_phy is port(
    clk, buffer_strobe, crc_strobe, reset : in std_logic;
    crc_in : in std_logic_vector(14 downto 0);
    parallel_in : in std_logic_vector(7 downto 0);
    clk_frequency : in integer range 1 to 255;
    serial_out : out std_logic;
    busy : out std_logic);
end can_phy;

architecture behavioral of can_phy is
    
    type state_type is (
        -- idle state
        idle,
        -- buffering header + data from ALU via parallel_in
        buffering, 
        -- transmitting data from tx_buffer
        tx_data, 
        -- transmitting CRC from tx_crc_buffer
        tx_crc,
        -- all the other single-cycle states for transmitting control bits
        tx_crc_delimiter,
        tx_ack,
        tx_ack_delimiter,
        tx_eof_6, tx_eof_5, tx_eof_4, tx_eof_3, tx_eof_2, tx_eof_1, tx_eof_0,
        tx_ifs_2, tx_ifs_1, tx_ifs_0);

    -- the actual bit that we are transmitting
    signal can_out : std_logic;
    -- the bit that we would be transmitting if stuffing was not a thing
    signal can_out_pre_stuffing : std_logic;

    -- 83 bit tx buffer:
    -- 19 bits header
    -- up to 64 bits data
    -- (15 bits tx_crc stored separately)
    -- ACK, IFS, etc via state machine
    constant TX_BUFFER_MAX : integer := 82;

    -- the virtual header + data transmission buffer
    -- in reality, this is not necessarily a contiguous block of memory
    -- it once was, but word alignment and addressing during buffering was a bottleneck
    -- so now we have *a lot* of single-word buffers, and we just concatenate them here
    signal tx_buffer : std_logic_vector(TX_BUFFER_MAX downto 0);

    -- the buffer size counter is 0 when the buffer is full
    constant TX_BUFFER_SIZE_COUNTER_MAX : integer := 11;
    -- we are counting words here, starting at the top of the buffer, and going down
    -- this way we already have everything in network order, and can just go down bit by bit for transmission
    signal tx_buffer_size_counter, tx_buffer_size_counter_next : unsigned(3 downto 0) := to_unsigned(TX_BUFFER_SIZE_COUNTER_MAX, 4);
    signal tx_end_of_data : std_logic_vector(6 downto 0);

    -- top buffer only contains 3 bits, because the header is only 19 bits
    signal tx_buffer_10, tx_buffer_10_next : std_logic_vector(2 downto 0);

    -- all the other buffers contain 8 bits.
    -- this is ugly, but that's what optimization does to your code
    -- we could probably have used a RAM here, but that would be a pain for bit-level access
    -- idk, maybe that's possible, but this was easier, works, and allows the synthesizer to optimize
    -- and move the buffer chunks around as it sees fit
    signal tx_buffer_9, tx_buffer_8, tx_buffer_7, tx_buffer_6, tx_buffer_5, 
           tx_buffer_4, tx_buffer_3, tx_buffer_2, tx_buffer_1, tx_buffer_0 : std_logic_vector(7 downto 0);
        
    signal tx_buffer_9_next, tx_buffer_8_next, tx_buffer_7_next, tx_buffer_6_next, tx_buffer_5_next, 
           tx_buffer_4_next, tx_buffer_3_next, tx_buffer_2_next, tx_buffer_1_next, tx_buffer_0_next : std_logic_vector(7 downto 0);

    -- the data bit pointer points to the next bit to be transmitted
    -- also starting at the top of the buffer, and going down
    signal tx_bit_pointer : integer range TX_BUFFER_MAX downto 0 := 0;
    signal tx_bit_pointer_next : integer range TX_BUFFER_MAX downto 0 := 0;

    -- inclusive CRC buffer upper bound in bits
    constant TX_CRC_BUFFER_MAX : integer := 14;

    -- the CRC buffer contains the 15 bit CRC
    signal tx_crc_buffer, tx_crc_buffer_next : std_logic_vector(TX_CRC_BUFFER_MAX downto 0);

    -- the tx_crc bit pointer points to the next CRC bit to be transmitted
    -- to ensure network order, the CRC is transmitted MSB first (pointer goes down)
    signal tx_crc_bit_pointer : integer range TX_CRC_BUFFER_MAX downto 0 := 0;
    signal tx_crc_bit_pointer_next : integer range TX_CRC_BUFFER_MAX downto 0 := 0;

    -- the state machine
    signal state : state_type := idle;
    signal next_state : state_type := idle;

    -- the stuffing bit is the bit that will be inserted to ensure that there are no more than 5 consecutive bits of the same value
    signal stuffing_bit : std_logic := '0';
    
    -- the stuffing register contains the last 5 bits that were transmitted
    -- we need to keep track of them to know when to insert a stuffing bit
    -- at the beginning we don't know what the last 5 bits were, so we just set them to X
    -- Idk if this works in reality, but it works in simulation, and that's all that matters :)
    signal stuffing, stuffing_next : std_logic_vector(4 downto 0) := (others => 'X');

    -- whether or not we need to insert a stuffing bit
    signal requires_stuffing : boolean;
    
    -- we need to throttle everything to the CAN bus frequency when transmitting
    -- so we just count cycles
    signal tx_cycle_counter, tx_cycle_counter_next : integer range 1 to 255;
    
    -- pulse to simulate a rising edge clock when in throttled mode
    signal rising_edge_tx_clock : boolean;
begin
    
    -- update all the flip flops
    -- it's a lot of them (around 200, I think), so not very space efficient
    -- but that never was the goal anyway
    refresh_state : process(clk, reset)
    begin
        if (rising_edge(clk)) then
            if (reset = '1') then
                state <= idle;
                tx_crc_buffer <= (others => '0');
                tx_bit_pointer <= TX_BUFFER_MAX;
                tx_crc_bit_pointer <= TX_CRC_BUFFER_MAX;
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
                tx_cycle_counter <= 1;
                stuffing <= (others => 'X');
            else
                state <= next_state;
                tx_crc_buffer <= tx_crc_buffer_next;
                tx_bit_pointer <= tx_bit_pointer_next;
                tx_crc_bit_pointer <= tx_crc_bit_pointer_next;
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
                tx_cycle_counter <= tx_cycle_counter_next;
                stuffing <= stuffing_next;
            end if;
        end if;
    end process refresh_state;
    
    -- only during transmission, we need to throttle the clock
    -- originally, we actually throttled the clock, but that was a pain
    -- and we had a lot of weird negative timing slack issues to a point
    -- where even running the thing a 1 Hz was not possible
    -- so now we just count cycles, and simulate a rising edge clock
    -- through the state machine.
    -- works better, is easier to understand, and is more flexible
    -- idk why we didn't do that in the first place
    underclock: process(state, tx_cycle_counter, clk_frequency)
    begin
        -- we need to be responsive while idling and buffering
        -- and can do so at full speed
        if (state /= idle and state /= buffering) then
            if (tx_cycle_counter < clk_frequency) then
                tx_cycle_counter_next <= tx_cycle_counter + 1;
                rising_edge_tx_clock <= false;
            else
                tx_cycle_counter_next <= 1;
                rising_edge_tx_clock <= true;
            end if;
        else
            tx_cycle_counter_next <= 1;
            rising_edge_tx_clock <= true;
        end if;
    end process underclock;

    -- end of data counter is in words, so "multiply" by 8
    tx_end_of_data <= std_logic_vector(tx_buffer_size_counter) & "000";

    -- the beautiful transmission buffer concatenation nightmare
    -- not clean, but it works, and it's 3ns faster than a continuous block of memory
    tx_buffer <= tx_buffer_10 & tx_buffer_9 & tx_buffer_8 & tx_buffer_7 & tx_buffer_6 
                & tx_buffer_5 & tx_buffer_4 & tx_buffer_3 & tx_buffer_2 & tx_buffer_1 & tx_buffer_0;

    -- the state machine
    transition : process(state, buffer_strobe, tx_bit_pointer, tx_crc_bit_pointer, tx_end_of_data, rising_edge_tx_clock)
    begin
        if (state = idle or state = buffering or rising_edge_tx_clock) then
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
                -- all the other single-cycle states
                -- not very elegant, but it works
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
        else
            next_state <= state;
        end if;
    end process transition;

    -- refresh the crc buffer or save new values
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

    -- this counter is in words and counts from the top of the buffer down
    -- it is used as a termination condition for the data transmission
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
    -- really, really ugly, but it works
    -- we could probably work with generate statements here, but that would probably take more
    -- time than just copy-pasting this 10 times and letting GitHub Copilot figure out the rest
    -- even though this is like 10 times more code this is actually way faster than the previous 
    -- pointer based approach on the long contiguous buffer
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
    
    -- we require stuffing if the last 5 bits were all the same
    requires_stuffing <= stuffing = "00000" or stuffing = "11111";
    -- the stuffing bit is the bit that will be inserted
    stuffing_bit <= not stuffing(0);
    
    -- update the stuffing shift register
    set_stuffing_next : process(state, stuffing, can_out_pre_stuffing, requires_stuffing, stuffing_bit, rising_edge_tx_clock)
    begin
        -- if we are buffering (state before transmission), reset the stuffing register to tri-state
        if (state = buffering) then
            stuffing_next <= (others => 'X');
        -- if there is no simulated rising edge clock, we hold the stuffing register
        elsif (not rising_edge_tx_clock) then
            stuffing_next <= stuffing;
        -- if we need to insert a stuffing bit, we shift the stuffing register and insert the stuffing bit
        elsif (requires_stuffing) then
            stuffing_next <= stuffing(3 downto 0) & stuffing_bit;
        else
            -- otherwise, we shift the stuffing register and insert the bit that we are transmitting
            stuffing_next <= stuffing(3 downto 0) & can_out_pre_stuffing;
        end if;
    end process set_stuffing_next;

    -- update the transmit bit pointer
    set_next_tx_bit_counter : process(state, tx_bit_pointer, requires_stuffing, rising_edge_tx_clock)
    begin
        if (state = tx_data) then
            if (rising_edge_tx_clock and not requires_stuffing) then
                tx_bit_pointer_next <= tx_bit_pointer - 1;
            else 
                tx_bit_pointer_next <= tx_bit_pointer;
            end if;
        else
            -- if we are not transmitting data, reset the pointer
            tx_bit_pointer_next <= TX_BUFFER_MAX;
        end if;
    end process set_next_tx_bit_counter;

    -- update the transmit tx_crc bit pointer
    set_next_tx_crc_bit_counter : process(state, tx_crc_bit_pointer, requires_stuffing, rising_edge_tx_clock)
    begin
        if (state = tx_crc) then
            if (rising_edge_tx_clock and not requires_stuffing) then
                tx_crc_bit_pointer_next <= tx_crc_bit_pointer - 1;
            else
                tx_crc_bit_pointer_next <= tx_crc_bit_pointer;
            end if;
        else
            -- if we are not transmitting tx_crc, reset the pointer
            tx_crc_bit_pointer_next <= TX_CRC_BUFFER_MAX;
        end if;
    end process set_next_tx_crc_bit_counter;

    -- determine the next thing to transmit, independent of bit stuffing
    set_can_out_pre_stuffing : process(state, tx_buffer, tx_bit_pointer, tx_crc_buffer, tx_crc_bit_pointer)
    begin
        if (state = tx_data) then
            can_out_pre_stuffing <= tx_buffer(tx_bit_pointer);
        elsif (state = tx_crc) then
            can_out_pre_stuffing <= tx_crc_buffer(tx_crc_bit_pointer);
        elsif (state = tx_ack) then
            can_out_pre_stuffing <= '0';
        else
            -- all the other states just transmit 1, CAN really isn't that complicated looking at it like this
            can_out_pre_stuffing <= '1';
        end if;
    end process set_can_out_pre_stuffing;

    -- determine the next thing to transmit, including bit stuffing
    apply_stuffing : process(state, requires_stuffing, stuffing_bit, can_out_pre_stuffing)
    begin 
        if ((state = tx_data or state = tx_crc) and requires_stuffing) then
            -- gotta insert a stuffing bit
            can_out <= stuffing_bit;
        else
            -- otherwise, transmit whatever we are supposed to transmit
            can_out <= can_out_pre_stuffing;
        end if;
    end process apply_stuffing;

    --------------------------------------------------------------------------------
    -- output signals, not a lot to see here
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