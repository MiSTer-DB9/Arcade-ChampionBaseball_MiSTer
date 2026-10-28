//============================================================================
//
//  champbas_rom — ROM/BRAM regions for the Champion Baseball core, loaded
//  from the MRA via ioctl. Region sizes are the per-set maximum and the
//  layout is deliberately set-agnostic; set_id (MRA index 5) is captured here
//  and exported for the rest of the core.
//
//============================================================================

module champbas_rom
(
    input               clk,          // core/CPU clock, read side
    input               clk_dl,       // download clock (clk_sys), write side

    // ioctl download
    input               ioctl_download,
    input        [7:0]  ioctl_index,
    input        [24:0] ioctl_addr,
    input        [7:0]  ioctl_data,
    input               ioctl_wr,

    output logic [7:0]  set_id,       // from index 5

    // read ports (one per region)
    input        [14:0] maincpu_addr,   output [7:0] maincpu_data,
    input        [15:0] audiocpu_addr,  output [7:0] audiocpu_data,
    input        [13:0] gfx_p01_addr,   output [7:0] gfx_p01_data,
    input        [12:0] mcu_addr,       output [7:0] mcu_data,
    input         [9:0] prom_addr,      output [7:0] prom_data,
    input        [12:0] gfx_p3_addr,    output [7:0] gfx_p3_data,
    input        [12:0] gfx3_addr,      output [7:0] gfx3_data
);

    ////////////////////////////////////////////////////////////////////////
    // Per-region download write strobes
    ////////////////////////////////////////////////////////////////////////

    wire wr_maincpu  = ioctl_wr && ioctl_download && (ioctl_index == 8'd0);
    wire wr_audiocpu = ioctl_wr && ioctl_download && (ioctl_index == 8'd1);
    wire wr_gfx_p01  = ioctl_wr && ioctl_download && (ioctl_index == 8'd2);
    wire wr_mcu      = ioctl_wr && ioctl_download && (ioctl_index == 8'd6);
    wire wr_prom     = ioctl_wr && ioctl_download && (ioctl_index == 8'd7);
    wire wr_gfx_p3   = ioctl_wr && ioctl_download && (ioctl_index == 8'd8);
    wire wr_gfx3     = ioctl_wr && ioctl_download && (ioctl_index == 8'd9);

    // index 3 (hiscore config) and index 4 (NVRAM) are not ROM regions

    ////////////////////////////////////////////////////////////////////////
    // Index 5 — set-id byte (NOT a BRAM region). Single byte, address 0.
    //   0x00 champbas    0x01 champbasj   0x02 champbasja  0x03 champbasjb
    //   0x04 champbb2    0x05 champbb2j   0x06 tbasebal    0x07 talbot
    //   0x08 exctsccr    0x09 exctscc2    0x0A exctsccrb
    ////////////////////////////////////////////////////////////////////////

    wire wr_set_id = ioctl_wr && ioctl_download && (ioctl_index == 8'd5) && (ioctl_addr == 25'd0);

    initial set_id = 8'd0;
    always @(posedge clk_dl) begin
        if (wr_set_id) set_id <= ioctl_data;
    end

    ////////////////////////////////////////////////////////////////////////
    // Index 0 - main Z80 program.
    // Max real use 0x8000 (champbb2, non-contiguous — padded in its MRA).
    ////////////////////////////////////////////////////////////////////////

    dpram_dc #(.widthad_a(15), .width_a(8)) maincpu_rom
    (
        .clock_a(clk),
        .address_a(maincpu_addr),
        .q_a(maincpu_data),

        .clock_b(clk_dl),
        .address_b(ioctl_addr[14:0]),
        .data_b(ioctl_data),
        .wren_b(wr_maincpu)
    );

    ////////////////////////////////////////////////////////////////////////
    // Index 1 - sound Z80 program.
    // Max real use 0x9000 (exctsccr, 5 ROMs); 64K so the full Z80 address indexes it.
    ////////////////////////////////////////////////////////////////////////

    dpram_dc #(.widthad_a(16), .width_a(8)) audiocpu_rom
    (
        .clock_a(clk),
        .address_a(audiocpu_addr),
        .q_a(audiocpu_data),

        .clock_b(clk_dl),
        .address_b(ioctl_addr[15:0]),
        .data_b(ioctl_data),
        .wren_b(wr_audiocpu)
    );

    ////////////////////////////////////////////////////////////////////////
    // Index 2 - gfx planes 0/1, tiles then sprites; the video picks the half with
    // an address bit (0x2000 per half for the champbas family, 0x1000 for Talbot).
    ////////////////////////////////////////////////////////////////////////

    dpram_dc #(.widthad_a(14), .width_a(8)) gfx_p01_rom
    (
        .clock_a(clk),
        .address_a(gfx_p01_addr),
        .q_a(gfx_p01_data),

        .clock_b(clk_dl),
        .address_b(ioctl_addr[13:0]),
        .data_b(ioctl_data),
        .wren_b(wr_gfx_p01)
    );

    ////////////////////////////////////////////////////////////////////////
    // Index 6 - ALPHA-8201 / 8302 MCU program.
    ////////////////////////////////////////////////////////////////////////

    dpram_dc #(.widthad_a(13), .width_a(8)) mcu_rom
    (
        .clock_a(clk),
        .address_a(mcu_addr),
        .q_a(mcu_data),

        .clock_b(clk_dl),
        .address_b(ioctl_addr[12:0]),
        .data_b(ioctl_data),
        .wren_b(wr_mcu)
    );

    ////////////////////////////////////////////////////////////////////////
    // Index 7 — colour PROMs (palette +
    // pen->color LUT, one or two PROMs depending on set). Max real use
    // 0x220 (exctsccr: 3 PROMs).
    ////////////////////////////////////////////////////////////////////////

    dpram_dc #(.widthad_a(10), .width_a(8)) prom_rom
    (
        .clock_a(clk),
        .address_a(prom_addr),
        .q_a(prom_data),

        .clock_b(clk_dl),
        .address_b(ioctl_addr[9:0]),
        .data_b(ioctl_data),
        .wren_b(wr_prom)
    );

    ////////////////////////////////////////////////////////////////////////
    // Index 8 - exctsccr tile / sprite plane-2 source ROM (6_c5), stored raw;
    // the video selects the nibble (address >= 0x1000 = high).
    ////////////////////////////////////////////////////////////////////////

    dpram_dc #(.widthad_a(13), .width_a(8)) gfx_p3_rom
    (
        .clock_a(clk),
        .address_a(gfx_p3_addr),
        .q_a(gfx_p3_data),

        .clock_b(clk_dl),
        .address_b(ioctl_addr[12:0]),
        .data_b(ioctl_data),
        .wren_b(wr_gfx_p3)
    );

    ////////////////////////////////////////////////////////////////////////
    // Index 9 - 4bpp sprites (Exciting Soccer family).
    ////////////////////////////////////////////////////////////////////////

    dpram_dc #(.widthad_a(13), .width_a(8)) gfx3_rom
    (
        .clock_a(clk),
        .address_a(gfx3_addr),
        .q_a(gfx3_data),

        .clock_b(clk_dl),
        .address_b(ioctl_addr[12:0]),
        .data_b(ioctl_data),
        .wren_b(wr_gfx3)
    );

endmodule
