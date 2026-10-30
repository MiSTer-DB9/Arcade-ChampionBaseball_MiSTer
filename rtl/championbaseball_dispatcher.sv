//============================================================================
//
//  Champion Baseball dispatcher: shared CPU / MCU / sound chip / ROM / RAM pools + the boards (rtl/boards/)
//  Copyright (C) 2026 Rodimus
//
//    49.152 / 16 = 3.072 MHz = XTAL 18.432 / 6  -> both Z80s
//    49.152 /  8 = 6.144 MHz = XTAL 18.432 / 3  -> pixel clock
//
//============================================================================

module championbaseball_dispatcher
(
    input                reset,
    input                clk_49m,

    // ---- controls, assembled into the board's port order by the wrapper
    input          [7:0] p1,
    input          [7:0] p2,
    input          [7:0] dsw,          // bit 7 is ignored; the main board substitutes the watchdog bit
    input          [7:0] system,

    // ---- video
    output               video_hsync, video_vsync,
    output               video_hblank, video_vblank,
    output               ce_pix,
    output         [7:0] video_r, video_g, video_b,

    // ---- audio
    output signed [15:0] sound_l,
    output signed [15:0] sound_r,

    // ---- ROM download
    input         [24:0] ioctl_addr,
    input          [7:0] ioctl_data,
    input                ioctl_wr,
    input          [7:0] ioctl_index,
    input                ioctl_download,

    output         [7:0] set_id,       // MRA index 5, exposed for the wrapper's OSD/rotation logic

    // ---- hiscore RAM access (routed inside MAIN to main RAM or the 7C00 block)
    input         [15:0] hs_addr,
    input          [7:0] hs_din,
    output         [7:0] hs_dout,
    input                hs_we,
    input                hs_active,

    input                crt_flip,     // OSD CRT Flip — raster mirror in VIDEO (game flip stays separate)

    input                pause
);

//------------------------------------------------------- Clock enables -------------------------------------------------------//

reg [4:0] cen_cnt = 5'd0;
always_ff @(posedge clk_49m) cen_cnt <= cen_cnt + 5'd1;

wire cen_cpu = (cen_cnt[3:0] == 4'd0);   // 1-in-16 -> 3.072 MHz  (18.432/6)
wire cen_pix = (cen_cnt[2:0] == 3'd0);   // 1-in-8  -> 6.144 MHz  (18.432/3)
wire cen_ay  = (cen_cnt      == 5'd0);   // 1-in-32 -> 1.536 MHz  (18.432/12)

assign ce_pix = cen_pix;

//------------------------------------------------------- ROM regions ---------------------------------------------------------//

wire [14:0] maincpu_addr;
wire  [7:0] maincpu_data;
wire [15:0] audiocpu_addr;
wire  [7:0] audiocpu_data;
wire [13:0] gfx_p01_addr;
wire  [7:0] gfx_p01_data;
wire  [9:0] prom_addr;
wire  [7:0] prom_data;
wire [12:0] gfx_p3_addr;
wire  [7:0] gfx_p3_data;
wire [12:0] gfx3_addr;
wire  [7:0] gfx3_data;

wire [12:0] mcu_addr;
wire  [7:0] mcu_data;

champbas_rom rom
(
    .clk(clk_49m),
    .clk_dl(clk_49m),

    .ioctl_download(ioctl_download),
    .ioctl_index(ioctl_index),
    .ioctl_addr(ioctl_addr),
    .ioctl_data(ioctl_data),
    .ioctl_wr(ioctl_wr),

    .set_id(set_id),

    .maincpu_addr(maincpu_addr),   .maincpu_data(maincpu_data),
    .gfx_p01_addr(gfx_p01_addr),   .gfx_p01_data(gfx_p01_data),
    .prom_addr(prom_addr),         .prom_data(prom_data),

    .audiocpu_addr(audiocpu_addr), .audiocpu_data(audiocpu_data),

    .gfx_p3_addr(gfx_p3_addr),     .gfx_p3_data(gfx_p3_data),

    .gfx3_addr(gfx3_addr),         .gfx3_data(gfx3_data),

    // ALPHA MCU program (index 6) for pool slot mcu_0
    .mcu_addr(mcu_addr),           .mcu_data(mcu_data)
);

//------------------------------------------------------- Chip pool -----------------------------------------------------------//
// z80_0 main Z80 / mcu_0 ALPHA MCU (main board); z80_1 sound Z80 and ay_0 (one sound board at a time, use_exctsccr_snd);
// ay_1-3 the Exciting Soccer board's other AYs

wire use_exctsccr_snd = (set_id == 8'h08) || (set_id == 8'h09);

chip_pool_pkg::z80r_i_t      z80_0_i, z80_1_i, cb_z80_i, es_z80_i;
chip_pool_pkg::z80r_o_t      z80_0_o, z80_1_o;
chip_pool_pkg::alpha8201_i_t mcu_0_i;
chip_pool_pkg::alpha8201_o_t mcu_0_o;
chip_pool_pkg::ayr_i_t       cb_ay_i;
chip_pool_pkg::ayr_i_t [3:0] es_ay_i, ay_i;
chip_pool_pkg::ay_o_t  [3:0] ay_o;

assign z80_1_i = use_exctsccr_snd ? es_z80_i : cb_z80_i;
assign ay_i    = use_exctsccr_snd ? es_ay_i : {es_ay_i[3:1], cb_ay_i};

T80s z80_0
(
    .RESET_n(z80_0_i.reset_n), .CLK(clk_49m), .CEN(z80_0_i.ce), .WAIT_n(1'b1), .INT_n(z80_0_i.int_n), .NMI_n(z80_0_i.nmi_n),
    .BUSRQ_n(1'b1), .M1_n(z80_0_o.m1_n), .MREQ_n(z80_0_o.mreq_n), .IORQ_n(z80_0_o.iorq_n), .RD_n(z80_0_o.rd_n),
    .WR_n(z80_0_o.wr_n), .RFSH_n(z80_0_o.rfsh_n), .A(z80_0_o.a), .DI(z80_0_i.di), .DO(z80_0_o.dout)
);

T80s z80_1
(
    .RESET_n(z80_1_i.reset_n), .CLK(clk_49m), .CEN(z80_1_i.ce), .WAIT_n(1'b1), .INT_n(z80_1_i.int_n), .NMI_n(z80_1_i.nmi_n),
    .BUSRQ_n(1'b1), .M1_n(z80_1_o.m1_n), .MREQ_n(z80_1_o.mreq_n), .IORQ_n(z80_1_o.iorq_n), .RD_n(z80_1_o.rd_n),
    .WR_n(z80_1_o.wr_n), .RFSH_n(z80_1_o.rfsh_n), .A(z80_1_o.a), .DI(z80_1_i.di), .DO(z80_1_o.dout)
);

alpha8201 #(.CEN_DIV(16'd511)) mcu_0
(
    .clk(clk_49m), .reset(mcu_0_i.reset), .pause(mcu_0_i.pause), .mcu_start(mcu_0_i.mcu_start), .bus_dir(mcu_0_i.bus_dir),
    .ext_addr(mcu_0_i.ext_addr), .ext_din(mcu_0_i.ext_din), .ext_dout(mcu_0_o.ext_dout), .ext_we(mcu_0_i.ext_we),
    .mcu_addr(mcu_0_o.mcu_addr), .mcu_data(mcu_0_i.mcu_data),
    .dbg_pc(), .dbg_op(), .dbg_illegal(), .dbg_mcu_ram_addr(), .dbg_mcu_rd_en(), .dbg_mcu_wr_en()
);

generate
    genvar k;
    for (k = 0; k < 4; k = k + 1) begin : g_ay
        jt49_bus #(.COMP(3'b100)) ay
        (
            .rst_n(ay_i[k].rst_n), .clk(clk_49m), .clk_en(ay_i[k].ce), .bdir(ay_i[k].bdir), .bc1(ay_i[k].bc1),
            .din(ay_i[k].din), .sel(1'b1), .dout(ay_o[k].dout), .sound(ay_o[k].sound), .A(ay_o[k].a), .B(ay_o[k].b),
            .C(ay_o[k].c), .sample(), .IOA_in(ay_i[k].ioa_in), .IOA_out(), .IOB_in(ay_i[k].iob_in), .IOB_out(ay_o[k].iob_out)
        );
    end
endgenerate

//------------------------------------------------------- Board RAM pool ------------------------------------------------------//
// block      main board                      sound board
//   0  2K    work RAM 8800 (port B hiscore)
//   1  1K    ext RAM 6000 (no-MCU sets)
//   2  1K    RAM 7C00 (Exciting Soccer, port B hiscore)
//   3  2K    video tile RAM (CPU / copy)
//   4  2K    video tile shadow (copy / display)
//   5  2K                                    sound RAM (Champion Baseball board 1K, Exciting Soccer board 2K)

ram_pool_pkg::pram_i_t [4:0] m_pr_i;
ram_pool_pkg::pram_i_t       cb_pr_i, es_pr_i;
ram_pool_pkg::pram_i_t [5:0] pool_i;
ram_pool_pkg::pram_o_t [5:0] pool_o;
assign pool_i = {use_exctsccr_snd ? es_pr_i : cb_pr_i, m_pr_i};

dpram_dc #(.widthad_a(11), .width_a(8)) ram_0
(
    .clock_a(clk_49m), .wren_a(pool_i[0].a_we), .address_a(pool_i[0].a_addr[10:0]), .data_a(pool_i[0].a_d), .q_a(pool_o[0].a_q),
    .clock_b(clk_49m), .wren_b(pool_i[0].b_we), .address_b(pool_i[0].b_addr[10:0]), .data_b(pool_i[0].b_d), .q_b(pool_o[0].b_q)
);
dpram_dc #(.widthad_a(10), .width_a(8)) ram_1
(
    .clock_a(clk_49m), .wren_a(pool_i[1].a_we), .address_a(pool_i[1].a_addr[9:0]), .data_a(pool_i[1].a_d), .q_a(pool_o[1].a_q),
    .clock_b(clk_49m), .wren_b(pool_i[1].b_we), .address_b(pool_i[1].b_addr[9:0]), .data_b(pool_i[1].b_d), .q_b(pool_o[1].b_q)
);
dpram_dc #(.widthad_a(10), .width_a(8)) ram_2
(
    .clock_a(clk_49m), .wren_a(pool_i[2].a_we), .address_a(pool_i[2].a_addr[9:0]), .data_a(pool_i[2].a_d), .q_a(pool_o[2].a_q),
    .clock_b(clk_49m), .wren_b(pool_i[2].b_we), .address_b(pool_i[2].b_addr[9:0]), .data_b(pool_i[2].b_d), .q_b(pool_o[2].b_q)
);
dpram_dc #(.widthad_a(11), .width_a(8)) ram_3
(
    .clock_a(clk_49m), .wren_a(pool_i[3].a_we), .address_a(pool_i[3].a_addr[10:0]), .data_a(pool_i[3].a_d), .q_a(pool_o[3].a_q),
    .clock_b(clk_49m), .wren_b(pool_i[3].b_we), .address_b(pool_i[3].b_addr[10:0]), .data_b(pool_i[3].b_d), .q_b(pool_o[3].b_q)
);
dpram_dc #(.widthad_a(11), .width_a(8)) ram_4
(
    .clock_a(clk_49m), .wren_a(pool_i[4].a_we), .address_a(pool_i[4].a_addr[10:0]), .data_a(pool_i[4].a_d), .q_a(pool_o[4].a_q),
    .clock_b(clk_49m), .wren_b(pool_i[4].b_we), .address_b(pool_i[4].b_addr[10:0]), .data_b(pool_i[4].b_d), .q_b(pool_o[4].b_q)
);
dpram_dc #(.widthad_a(11), .width_a(8)) ram_5
(
    .clock_a(clk_49m), .wren_a(pool_i[5].a_we), .address_a(pool_i[5].a_addr[10:0]), .data_a(pool_i[5].a_d), .q_a(pool_o[5].a_q),
    .clock_b(clk_49m), .wren_b(pool_i[5].b_we), .address_b(pool_i[5].b_addr[10:0]), .data_b(pool_i[5].b_d), .q_b(pool_o[5].b_q)
);

//------------------------------------------------------- Main board ----------------------------------------------------------//

wire [7:0] ay_din;
wire       ay_addr_wr, ay_data_wr;
wire [7:0] sound_latch;
wire       sound_latch_wr;

ChampionBaseball_MAIN main_board
(
    .mcu_addr(mcu_addr),
    .mcu_data(mcu_data),

    .clk(clk_49m),
    .cen_cpu(cen_cpu),
    .cen_pix(cen_pix),
    .reset(reset),
    .pause(pause),

    .p1(p1),
    .p2(p2),
    .dsw(dsw),
    .system(system),

    .set_id(set_id),

    .hs_addr(hs_addr),
    .hs_din(hs_din),
    .hs_dout(hs_dout),
    .hs_we(hs_we),
    .hs_active(hs_active),

    .crt_flip(crt_flip),

    .rom_addr(maincpu_addr),
    .rom_data(maincpu_data),

    .gfx_addr(gfx_p01_addr),
    .gfx_data(gfx_p01_data),
    .prom_addr(prom_addr),
    .prom_data(prom_data),

    .gfx_p3_addr(gfx_p3_addr),
    .gfx_p3_data(gfx_p3_data),
    .gfx3_addr(gfx3_addr),
    .gfx3_data(gfx3_data),

    .ay_din(ay_din),
    .ay_addr_wr(ay_addr_wr),
    .ay_data_wr(ay_data_wr),

    .sound_latch(sound_latch),
    .sound_latch_wr(sound_latch_wr),

    .clk_dl(clk_49m),
    .ioctl_download(ioctl_download),
    .ioctl_index(ioctl_index),
    .ioctl_addr(ioctl_addr),
    .ioctl_data(ioctl_data),
    .ioctl_wr(ioctl_wr),

    .video_r(video_r),
    .video_g(video_g),
    .video_b(video_b),
    .video_hsync(video_hsync),
    .video_vsync(video_vsync),
    .video_hblank(video_hblank),
    .video_vblank(video_vblank),

    .z80_0_i(z80_0_i), .z80_0_o(z80_0_o), .mcu_0_i(mcu_0_i), .mcu_0_o(mcu_0_o),
    .pr_i(m_pr_i), .pr_o(pool_o[4:0])
);

//------------------------------------------------------- Sound board ---------------------------------------------------------//

// exctsccr / exctscc2 have their own sound board (14.318181 MHz crystal, 4 AYs, 2 DACs); the exctsccrb bootleg (0A)
// uses the champbas sound board
wire signed [15:0] snd_mono;
wire signed [15:0] snd_exctsccr;
wire        [15:0] audiocpu_addr_cb;
wire        [15:0] audiocpu_addr_es;

// Only one board is selected at a time; both share the index-1 audio ROM port.
assign audiocpu_addr = use_exctsccr_snd ? audiocpu_addr_es : audiocpu_addr_cb;

ChampionBaseball_SND snd_board
(
    .clk(clk_49m),
    .cen_cpu(cen_cpu),
    .cen_ay(cen_ay),
    .reset(reset | use_exctsccr_snd),
    .pause(pause),

    .sound_latch(sound_latch),
    .sound_latch_wr(sound_latch_wr),

    // The AY physically lives on the MAIN board and is written by the MAIN CPU
    .ay_din(ay_din),
    .ay_addr_wr(ay_addr_wr),
    .ay_data_wr(ay_data_wr),

    .rom_addr(audiocpu_addr_cb),
    .rom_data(audiocpu_data),

    .sound_out(snd_mono),

    .z80_1_i(cb_z80_i), .z80_1_o(z80_1_o), .ay_0_i(cb_ay_i), .ay_0_o(ay_o[0]), .pr_i(cb_pr_i), .pr_o(pool_o[5])
);

ExcitingSoccer_SND snd_board_es
(
    .clk(clk_49m),
    .reset(reset | ~use_exctsccr_snd),
    .pause(pause),

    .is_exctscc2(set_id == 8'h09),

    .sound_latch(sound_latch),
    .sound_latch_wr(sound_latch_wr),

    .rom_addr(audiocpu_addr_es),
    .rom_data(audiocpu_data),

    .sound_out(snd_exctsccr),

    .z80_1_i(es_z80_i), .z80_1_o(z80_1_o), .ay_i(es_ay_i), .ay_o(ay_o), .pr_i(es_pr_i), .pr_o(pool_o[5])
);

wire signed [15:0] snd_sel = use_exctsccr_snd ? snd_exctsccr : snd_mono;

// Both boards are mono — one SPEAKER each
assign sound_l = snd_sel;
assign sound_r = snd_sel;

endmodule
