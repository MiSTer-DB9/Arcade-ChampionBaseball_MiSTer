//============================================================================
//  board_template.sv - start a new Champion Baseball-core board by copying this file (NOT in files.qip, never compiled).
//  Copyright (C) 2026 Rodimus
//
//  Boards never instantiate a CPU, MCU, sound chip, ROM store or board RAM. They live ONCE in the dispatcher
//  rtl/championbaseball_dispatcher.sv: Z80s z80_0 (main) / z80_1 (sound), ALPHA-8201/8302 mcu_0, AY-3-8910 ay_0-3
//  (chip_pool_pkg buses: z80r_*, alpha8201_*, ayr_i_t / ay_o_t), the ROM blocks in rtl/ram_rom/champbas_rom.sv
//  (one per MRA index) and the 6 board RAM pool blocks (ram_pool_pkg: 0 = 2K, 1-2 = 1K, 3-5 = 2K).
//  To add a board: copy this file to rtl/boards/<board>/<board>.sv, add it to files.qip + verilator/Makefile,
//  instance it in the dispatcher, put its buses on the dispatcher muxes (z80_1_i / ay_i / pool_i, selected by set_id)
//  and leave the pool blocks it doesn't use to the other board. A RAM bigger than its block = grow the block, never a
//  private dpram_dc. ROM images: load decode by ioctl index and address only, NEVER by set_id (index 5, the set id,
//  arrives after the ROMs). A RAM / chip that truly can't pool = "// POOL-EXCEPTION: <reason>" on its instance line +
//  a Pool contract row (Claude/ vault note). verilator/common/pool_check.sh (POOL_MODS) enforces it.
//============================================================================

module board_template
(
    input  logic        clk,            // 49.152 MHz
    input  logic        reset,          // core reset | this board inactive
    input  logic        pause,

    output chip_pool_pkg::z80r_i_t       z80_1_i,
    input  chip_pool_pkg::z80r_o_t       z80_1_o,
    output chip_pool_pkg::ayr_i_t  [3:0] ay_i,
    input  chip_pool_pkg::ay_o_t   [3:0] ay_o,

    output logic [15:0] rom_addr,       // sound ROM (index 1) read port
    input  logic  [7:0] rom_data,

    output ram_pool_pkg::pram_i_t        pr_i,   // pool block 5
    input  ram_pool_pkg::pram_o_t        pr_o,

    output logic signed [15:0] sound_out
);

assign z80_1_i   = '0;
assign ay_i      = '0;
assign rom_addr  = 16'd0;
assign pr_i      = '0;
assign sound_out = 16'sd0;

endmodule
