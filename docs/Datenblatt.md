# VHDL ALU + CAN - Datenblatt

_Gruppe: Ben Bekir Ertugrul, Frederik Höft und Manuele Waldheim_
_Ziel: Maximale Timingperformance_

Dieses Dokument liefert eine kurze technische Übersicht der VHDL-ALU.

## Eigenschaften

Die ALU arbeitet auf 8-Bit Eingaben und liefert 8 bis 16-Bit Ausgaben, je nach Operation. Operationen werden über 4-Bit Microcode Wörter gesteuert. Die maximale Taktfrequenz wurde mit Xilinx ISE für Xilinx Spartan-3E (XC3S500E-VQ100) FPGAs durch Post-Route-Timing Analysen ermittelt und liegt für die ALU bei 139.179 MHz, bzw 7.185 ns pro Taktzyklus. Der erwartete gesamt-Stromverbraucht beträgt 135.19 mW. Weitere Informationen zur Leistungsaufnahme sind unter [Power Consumption](#power-consumption) zu finden.

## Portdefinitionen

<div style="display: grid; grid-template-columns: 60% 39%; grid-column-gap: 1%">
<div>



</div>
<img src="./assets/block.png"/>
</div>

| Portname | Breite | Richtung | Common Name  | Anmerkungen |
|----------|--------|----------|--------------|--------------|
| `clk`      | 1      | Eingang  | Taktsignal   | < 139.179 MHz<br>rising edge<br>50% duty cycle |
| `reset`    | 1      | Eingang  | Reset        | Synchroner Reset<br>high-active<br>Jegliche Operation (inklusive CAN Übertragung) wird gestoppt, muss bei Initialisierung gesetzt werden.<br>Während Reset aktiv ist, werden alle weiteren Eingänge ignoriert. |
| `cmd`       | 4      | Eingang  | Operation    | 4-Bit Microcode Wort<br>Opcodes werden nur akzeptiert, wenn `ready = '0'` ist.<br>Eine Liste der unterstützten Operationen ist unter [Operationen](#operationen) zu finden. |
| `a`        | 8      | Eingang  | Operand A    | 8-Bit signed Operand A |
| `b`        | 8      | Eingang  | Operand B    | 8-Bit signed Operand B |
| `can_arbitration` | 12 | Eingang | CAN Arbitration | 12-Bit CAN Arbitration Field:<br>- 11-Bit CAN ID<br>- 1-Bit RTR (Remote Transmission Request)<br>Bitorder: `ID[10:0] RTR`<br>Weitere Informationen unter [Operationen](#operationen) |
| `clk_freqency` | 8 | Eingang | Clock Frequency | 8-Bit unsigned Clock Frequency in MHz<br>Wird für CAN Bit Timing verwendet.<br>Gibt die Taktfrequenz des `clk` Signals in MHz an.<br>Werte sollten aufgerundet werden.<br> `0` ist reserviert und darf nicht verwendet werden. |
| `flow` | 8 | Ausgang | Result Low Byte | 8-Bit Low Byte des Ergebnisses<br>MSB first<br>Siehe [Operationen](#operationen) für weitere Informationen |
| `fhigh` | 8 | Ausgang | Result High Byte | 8-Bit High Byte des Ergebnisses<br>MSB first<br>Siehe [Operationen](#operationen) für weitere Informationen |
| `ready` | 1 | Ausgang | Ready | low-active<br>`1`, wenn die ALU *nicht* bereit ist, eine weitere Operation auszuführen.<br>Gibt an, dass im nächsten Taktzyklus das Ergebnis einer vorherigen Operation verfügbar ist.<br>Wird ausschließlich als CRC-Interrupt für explizite CRC-Berechnungen verwendet.<br>Wird nicht für CAN-Übertragungen verwendet.<br>Wenn `ready = '1'`, werden keine weiteren Operationen erlaubt. |
| `crc_busy` | 1 | Ausgang | CRC Busy | high-active<br>`1`, wenn die ALU eine CRC-Berechnung durchführt.<br>Wenn `crc_busy = 1`, werden keine weiteren CRC, CAN, oder RAM Operationen erlaubt.<br>Andere Operationen können weiterhin ausgeführt werden, solange andere Busy Signale dies erlauben. |
| `can_busy` | 1 | Ausgang | CAN Busy | high-active<br>`1`, wenn die ALU eine CAN-Übertragung durchführt.<br>Wenn `can_busy = 1`, werden keine weiteren CAN Operationen erlaubt.<br>Andere Operationen können weiterhin ausgeführt werden, solange andere Busy Signale dies erlauben. |
| `can` | 1 | Ausgang | CAN TX | Serielles CAN Signal<br>inklusive bit stuffing, SOF, und Interframe Space<br>`1`, wenn idle<br>Taktfrequenz: 1 MHz<br>Bitorder: `SOF ID[10:0] RTR IDE r0 DLC Data[0..64] CRC[14:0] CRC_Delimiter ACK ACK_Delimiter EOF IFS`<br>Weitere Informationen unter [Operationen](#operationen) |
| `cout` | 1 | Ausgang | Carry Out-Flag | high-active<br>`1`, wenn ein Carry Out aufgetreten ist.<br>Wird für Operationen verwendet, die ein Carry Out erzeugen können.<br>Siehe [Operationen](#operationen) für weitere Informationen |
| `ov` | 1 | Ausgang | Overflow-Flag | high-active<br>`1`, wenn ein Overflow aufgetreten ist.<br>Wird für Operationen verwendet, die ein Overflow erzeugen können.<br>Siehe [Operationen](#operationen) für weitere Informationen |
| `equal` | 1 | Ausgang | Equal-Flag | high-active<br>`1`, wenn Operand A und Operand B Bit für Bit gleich sind.<br>Wird in jedem Taktzyklus und Kontext aktualisiert.<br>Unabhängig von Zustand, Busy signalen, oder Operationen.|
| `sign` | 1 | Ausgang | Sign-Flag | high-active<br>`1`, wenn das Ergebnis negativ ist.<br>Wird für Operationen verwendet, die ein Overflow erzeugen können.<br>Siehe [Operationen](#operationen) für weitere Informationen |

### Signalverhalten

## Operationen

TODO: Anmerkungen, Precondition, Flags, Cycles

| Code | PPASM | Operation | Common Name | Precondition | Flags | Cycles | Beschreibung | Anmerkungen |
|--------|-------|-----------|-------------|-----------------|-------|------------|--------------|-------------|
| `0000` | `add` | `flow[7:0] = a[7:0] + b[7:0]`   | Addition    |                 | `cout`, `ov`, `equal`, `sign` | 1 | Addition von Operand A und Operand B | |
| `0001` | `sub` | `flow[7:0] = a[7:0] - b[7:0]`   | Subtraction |                 | `cout`, `ov`, `equal`, `sign` | 1 | Subtraktion von Operand A und Operand B | |
| `0010` | `am2` | `flow[15:0] = (a<15:0> + b<15:0>) * 2` | Add-Multiply by 2 | | `cout`, `ov`, `equal`, `sign` | 1 | Addition von Operand A und Operand B, Ergebnis wird mit 2 multipliziert | |
| `0011` | `am4` | `flow[15:0] = (a<15:0> + b<15:0>) * 4` | Add-Multiply by 4 | | `cout`, `ov`, `equal`, `sign` | 1 | Addition von Operand A und Operand B, Ergebnis wird mit 4 multipliziert | |
| `0100` | `neg` | `flow[7:0] = -a[7:0]` | Negation | | `cout`, `ov`, `equal`, `sign` | 1 | Negation von Operand A | |
| `0101` | `shl` | `flow[7:0] = a[7:0] << 1` | Arithmetic Shift Left | | `cout`, `ov`, `equal`, `sign` | 1 | Arithmetischer Links-Shift von Operand A | |
| `0110` | `shr` | `flow[7:0] = a[7:0] >> 1` | Arithmetic Shift Right | | `cout`, `ov`, `equal`, `sign` | 1 | Arithmetischer Rechts-Shift von Operand A | |
| `0111` | `rol` | `flow[7:0] = a[7:0] <<< 1` | Rotate Left | | `cout`, `ov`, `equal`, `sign` | 1 | Links-Rotation von Operand A | |
| `1000` | `ror` | `flow[7:0] = a[7:0] >>> 1` | Rotate Right | | `cout`, `ov`, `equal`, `sign` | 1 | Rechts-Rotation von Operand A | |
| `1001` | `mul` | `flow[15:0] = a[7:0] * b[7:0]` | Multiplication | | `cout`, `ov`, `equal`, `sign` | 1 | Multiplikation von Operand A und Operand B | |
| `1010` | `nand` | `flow[7:0] = ~(a[7:0] & b[7:0])` | NAND | | `cout`, `ov`, `equal`, `sign` | 1 | Bitweises NAND von Operand A und Operand B | |
| `1011` | `xor` | `flow[7:0] = a[7:0] ^ b[7:0]` | XOR | | `cout`, `ov`, `equal`, `sign` | 1 | Bitweises XOR von Operand A und Operand B | |
| `1100` | `mov` | `RAM[b[7:0]] = a[7:0]` | Move | | | 1 | Schreibt Operand B in den RAM an der Adresse Operand A | |
| `1101` | `crc` | `flow[15:0] = pad0(CRC15(RAM[a[7:0]..b[7:0]]))` | CRC-15 | | `crc_busy` | 2 | Berechnet die CRC-15 Prüfsumme des RAM Bereichs zwischen Adressen A und B | |
| `1110` | `can` | `can <- SOF <can_arbitration> IDE r0 DLC RAM[a[7:0]..b[7:0]] CRC[14:0] CRC_Delimiter ACK ACK_Delimiter EOF IFS` | CAN TX | | `can_busy` | 1 | Sendet eine CAN Nachricht mit der angegebenen Arbitration ID und den Daten aus dem RAM zwischen Adressen A und B | |
| `1111` | `nop` | - | Reserved | | | 1 | Reserviert für zukünftige Erweiterungen, Verwendung auf eigene Gefahr als NOP | |

## Power Consumption

### On-Chip Power Summary

|        On-Chip        | Power (mW) |  Used  | Available | Utilization (%) |
|-----------------------|------------|--------|-----------|-----------------|
| Clocks                |       6.76 |      1 |    ---    |       ---       |
| Logic                 |       5.14 |    526 |      9312 |               6 |
| Signals               |       9.83 |    731 |    ---    |       ---       |
| IOs                   |      30.09 |     66 |        66 |             100 |
| BRAMs                 |       0.52 |      1 |        20 |               5 |
| MULTs                 |       0.27 |      1 |        20 |               5 |
| Static Power          |      82.58 |        |           |                 |
| Total                 |     135.19 |        |           |                 |

### Power Supply Summary

|                      | Total  | Dynamic | Static Power |
|----------------------|--------|---------|--------------|
| Supply Power (mW)    | 135.19 | 52.61   | 82.58        |

### Power Supply Currents


|     Supply Source     | Supply Voltage | Total Current (mA) | Dynamic Current (mA) | Quiescent Current (mA) |
|-----------------------|----------------|--------------------|----------------------|------------------------|
| Vccint                |          1.200 |              46.92 |                19.77 |                  27.15 |
| Vccaux                |          2.500 |              18.60 |                 0.60 |                  18.00 |
| Vcco25                |          2.500 |              12.96 |                10.96 |                   2.00 |
