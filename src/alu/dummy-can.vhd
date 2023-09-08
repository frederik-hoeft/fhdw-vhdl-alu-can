library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity can_phy_dummy is port(
    clk, buffer_strobe, crc_strobe, reset : in std_logic;
    crc_in : in std_logic_vector(14 downto 0);
    parallel_in : in std_logic_vector(7 downto 0);
    serial_out : out std_logic;
    busy : out std_logic);
end can_phy_dummy;

architecture mock of can_phy_dummy is
begin
    
    serial_out <= '1';
    busy <= '1';

end mock;