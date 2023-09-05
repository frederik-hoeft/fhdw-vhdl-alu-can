-- vim: ts=4 sw=4 expandtab

-- THIS IS GENERATED VHDL CODE.
-- https://bues.ch/h/crcgen
-- 
-- This code is Public Domain.
-- Permission to use, copy, modify, and/or distribute this software for any
-- purpose with or without fee is hereby granted.
-- 
-- THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
-- WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
-- MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY
-- SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES WHATSOEVER
-- RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN ACTION OF CONTRACT,
-- NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF OR IN CONNECTION WITH THE
-- USE OR PERFORMANCE OF THIS SOFTWARE.

-- CRC polynomial coefficients: x^15 + x^14 + x^10 + x^8 + x^7 + x^4 + x^3 + 1
--                              0x4599 (hex)
-- CRC width:                   15 bits
-- CRC shift direction:         left (big endian)
-- Input word width:            8 bits

library IEEE;
use IEEE.std_logic_1164.all;

entity crc15 is
    port (
        crcIn: in std_logic_vector(14 downto 0);
        data: in std_logic_vector(7 downto 0);
        crcOut: out std_logic_vector(14 downto 0)
    );
end entity crc15;

architecture Behavioral of crc15 is
begin
    crcOut(0) <= crcIn(7) xor crcIn(8) xor crcIn(9) xor crcIn(10) xor crcIn(11) xor crcIn(13) xor crcIn(14) xor data(0) xor data(1) xor data(2) xor data(3) xor data(4) xor data(6) xor data(7);
    crcOut(1) <= crcIn(8) xor crcIn(9) xor crcIn(10) xor crcIn(11) xor crcIn(12) xor crcIn(14) xor data(1) xor data(2) xor data(3) xor data(4) xor data(5) xor data(7);
    crcOut(2) <= crcIn(9) xor crcIn(10) xor crcIn(11) xor crcIn(12) xor crcIn(13) xor data(2) xor data(3) xor data(4) xor data(5) xor data(6);
    crcOut(3) <= crcIn(7) xor crcIn(8) xor crcIn(9) xor crcIn(12) xor data(0) xor data(1) xor data(2) xor data(5);
    crcOut(4) <= crcIn(7) xor crcIn(11) xor crcIn(14) xor data(0) xor data(4) xor data(7);
    crcOut(5) <= crcIn(8) xor crcIn(12) xor data(1) xor data(5);
    crcOut(6) <= crcIn(9) xor crcIn(13) xor data(2) xor data(6);
    crcOut(7) <= crcIn(7) xor crcIn(8) xor crcIn(9) xor crcIn(11) xor crcIn(13) xor data(0) xor data(1) xor data(2) xor data(4) xor data(6);
    crcOut(8) <= crcIn(0) xor crcIn(7) xor crcIn(11) xor crcIn(12) xor crcIn(13) xor data(0) xor data(4) xor data(5) xor data(6);
    crcOut(9) <= crcIn(1) xor crcIn(8) xor crcIn(12) xor crcIn(13) xor crcIn(14) xor data(1) xor data(5) xor data(6) xor data(7);
    crcOut(10) <= crcIn(2) xor crcIn(7) xor crcIn(8) xor crcIn(10) xor crcIn(11) xor data(0) xor data(1) xor data(3) xor data(4);
    crcOut(11) <= crcIn(3) xor crcIn(8) xor crcIn(9) xor crcIn(11) xor crcIn(12) xor data(1) xor data(2) xor data(4) xor data(5);
    crcOut(12) <= crcIn(4) xor crcIn(9) xor crcIn(10) xor crcIn(12) xor crcIn(13) xor data(2) xor data(3) xor data(5) xor data(6);
    crcOut(13) <= crcIn(5) xor crcIn(10) xor crcIn(11) xor crcIn(13) xor crcIn(14) xor data(3) xor data(4) xor data(6) xor data(7);
    crcOut(14) <= crcIn(6) xor crcIn(7) xor crcIn(8) xor crcIn(9) xor crcIn(10) xor crcIn(12) xor crcIn(13) xor data(0) xor data(1) xor data(2) xor data(3) xor data(5) xor data(6);
end architecture Behavioral;