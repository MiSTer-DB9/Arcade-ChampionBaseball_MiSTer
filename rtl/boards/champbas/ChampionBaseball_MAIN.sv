//============================================================================
//
//  ChampionBaseball_MAIN.sv - main Z80 board: memory map, LS259 mainlatch, watchdog, sprite position RAM,
//  ALPHA MCU bus and the video. The AY at 7000-7001 is on this board, not the sound board.
//  Per-set differences are selected by set_id (MRA index 5).
//
//============================================================================

module ChampionBaseball_MAIN
(
    input                clk,
    input                cen_cpu,        // 3.072 MHz enable
    input                cen_pix,        // 6.144 MHz enable
    input                reset,
    input                pause,

    // ---- controls (active low)
    input         [7:0]  p1,
    input         [7:0]  p2,
    input         [7:0]  dsw,            // bit 7 replaced by the watchdog bit
    input         [7:0]  system,

    input         [7:0]  set_id,         // MRA index 5

    // ---- hiscore RAM access (main RAM, RAM 7C, tilemap VRAM)
    input        [15:0]  hs_addr,
    input         [7:0]  hs_din,
    output        [7:0]  hs_dout,
    input                hs_we,
    input                hs_active,      // ram_intent_read | ram_intent_write

    input                crt_flip,       // OSD CRT Flip

    output       [12:0]  mcu_addr,
    input         [7:0]  mcu_data,

    // ---- main CPU ROM (champbas_rom index 0)
    output       [14:0]  rom_addr,
    input         [7:0]  rom_data,

    output       [13:0]  gfx_addr,
    input         [7:0]  gfx_data,
    output        [9:0]  prom_addr,
    input         [7:0]  prom_data,

    // gfx plane-2 source (champbas_rom index 8) — exctsccr family only
    output       [12:0]  gfx_p3_addr,
    input         [7:0]  gfx_p3_data,

    // 4bpp sprite gfx (champbas_rom index 9) — exctsccr family only
    output       [12:0]  gfx3_addr,
    input         [7:0]  gfx3_data,

    // ---- AY-3-8910 (main board, main CPU writes it)
    output        [7:0]  ay_din,
    output               ay_addr_wr,
    output               ay_data_wr,

    // ---- sound board latch
    output        [7:0]  sound_latch,
    output               sound_latch_wr,

    input                clk_dl,
    input                ioctl_download,
    input         [7:0]  ioctl_index,
    input        [24:0]  ioctl_addr,
    input         [7:0]  ioctl_data,
    input                ioctl_wr,

    // ---- video out
    output        [7:0]  video_r, video_g, video_b,
    output               video_hsync, video_vsync,
    output               video_hblank, video_vblank,

    // main Z80, ALPHA MCU and board RAM pool blocks 0-4 in the dispatcher rtl/championbaseball_dispatcher.sv
    output chip_pool_pkg::z80r_i_t      z80_0_i,
    input  chip_pool_pkg::z80r_o_t      z80_0_o,
    output chip_pool_pkg::alpha8201_i_t mcu_0_i,
    input  chip_pool_pkg::alpha8201_o_t mcu_0_o,
    output ram_pool_pkg::pram_i_t [4:0] pr_i,       // 0 main RAM, 1 ext RAM, 2 RAM 7C, 3-4 video tile RAM / shadow
    input  ram_pool_pkg::pram_o_t [4:0] pr_o
);

    ////////////////////////////////////////////////////////////////////////
    // Address decode
    //   A000       R  P1     | A000-A007  W  LS259 write_d0
    //   A040       R  P2     | A060-A06F  W  spriteram (x/y only)
    //   A080       R  DSW (mirror 0020) | A080  W  soundlatch
    //   A0C0       R  SYSTEM | A0C0      W  watchdog reset
    ////////////////////////////////////////////////////////////////////////

    wire [15:0] A;
    wire  [7:0] cpu_dout;
    wire        m1_n, mreq_n, iorq_n, rd_n, wr_n;

    // Per-set additions at 6000-68FF (champbas has nothing there):
    //   champbasj 01, champbb2 04/05, talbot 07, exctsccr family 08-0A: 6000-63FF = ALPHA shared RAM
    //   champbasja 02: 6000-63FF RAM + fake protection read at 6800-68FF
    //   champbasjb 03: 6000-63FF plain RAM
    wire set_has_extram = (set_id == 8'h01) || (set_id == 8'h02) || (set_id == 8'h03)
                       || (set_id == 8'h04) || (set_id == 8'h05)
                       || (set_id == 8'h07)
                       || ((set_id >= 8'h08) && (set_id <= 8'h0A));

    // sets where the ALPHA MCU owns the shared RAM (the exctsccrb bootleg has plain RAM there)
    wire set_has_mcu    = (set_id == 8'h01) || (set_id == 8'h04) || (set_id == 8'h05)
                       || (set_id == 8'h07)
                       || (set_id == 8'h08) || (set_id == 8'h09);
    wire set_has_prot   = (set_id == 8'h02);

    // exctsccr / exctscc2 map: adds RAM at 7C00-7FFF (no AY on the main board)
    wire set_is_exctsccr_full = (set_id == 8'h08) || (set_id == 8'h09);

    // Talbot: the MCU security-checks the watchdog bit, so only Talbot gets the watchdog reset
    wire set_is_talbot = (set_id == 8'h07);

    wire cs_extram = set_has_extram && (A[15:10] == 6'b0110_00);   // 6000-63FF
    wire cs_prot   = set_has_prot   && (A[15:8]  == 8'h68);        // 6800-68FF
    wire cs_ram7c  = set_is_exctsccr_full && (A[15:10] == 6'b0111_11);  // 7C00-7FFF

    // champbb2 / champbb2j: second ROM window at 7800-7FFF (MRA pads it to its place); it wins over the AY mirror
    wire set_has_rom78 = (set_id == 8'h04) || (set_id == 8'h05);   // champbb2, champbb2j
    wire cs_rom78 = set_has_rom78 && (A[15:11] == 5'b0111_1);      // 7800-7FFF
    wire cs_rom   = (A <  16'h6000) || cs_rom78;
    // AY at 7000-7001, mirrored across 7000-7FFF (A0 = register / data)
    wire cs_ay    = (A[15:12] == 4'h7) && !set_is_exctsccr_full && !cs_rom78;
    wire cs_vram  = (A[15:11] == 5'b1000_0);          // 8000-87FF
    wire cs_ram   = (A[15:11] == 5'b1000_1);          // 8800-8FFF
    wire cs_io    = (A[15:8]  == 8'hA0);

    // CPU write strobe: dead while paused. T80 holds its bus frozen, so an
    // ungated cen_cpu would re-fire the held write for the whole pause.
    wire cen_cpu_wr = cen_cpu & ~pause;

    wire mem_rd = ~mreq_n & ~rd_n;
    wire mem_wr = ~mreq_n & ~wr_n;

    // I/O quadrants A000 / A040 / A080 / A0C0 by A[7:6]
    wire io_q0 = cs_io & (A[7:6] == 2'b00);           // A000-A03F
    wire io_q1 = cs_io & (A[7:6] == 2'b01);           // A040-A07F
    wire io_q2 = cs_io & (A[7:6] == 2'b10);           // A080-A0BF  (DSW mirror 0x20 lands here)
    wire io_q3 = cs_io & (A[7:6] == 2'b11);           // A0C0-A0FF

    wire ls259_wr   = mem_wr & io_q0 & (A[5:3] == 3'b000);   // A000-A007
    wire spram_wr   = mem_wr & io_q1 & (A[5:4] == 2'b10);    // A060-A06F
    // exctsccr adds a SECOND sprite position RAM at A040-A04F 
    wire spram2_wr  = mem_wr & io_q1 & (A[5:4] == 2'b00);    // A040-A04F
    assign sound_latch_wr = mem_wr & io_q2;
    wire wdog_wr    = mem_wr & io_q3;

    assign sound_latch = cpu_dout;

    ////////////////////////////////////////////////////////////////////////
    // AY-3-8910 register select
    ////////////////////////////////////////////////////////////////////////

    localparam SET_CHAMPBB2J = 8'h05;                  // see any MRA's index-5 enumeration

    // exctsccr family = 0x08 exctsccr, 0x09 exctscc2, 0x0A exctsccrb
    wire is_exctsccr = (set_id >= 8'h08) && (set_id <= 8'h0A);

    wire ay_sel_inverted = (set_id == SET_CHAMPBB2J);
    wire ay_wr           = mem_wr & cs_ay;
    wire ay_is_addr      = ay_sel_inverted ? ~A[0] : A[0];

    assign ay_din     = cpu_dout;
    assign ay_addr_wr = ay_wr &  ay_is_addr;
    assign ay_data_wr = ay_wr & ~ay_is_addr;

    ////////////////////////////////////////////////////////////////////////
    // LS259 mainlatch @ 9D, written with D0
    ////////////////////////////////////////////////////////////////////////

    reg [7:0] mainlatch = 8'd0;

    always_ff @(posedge clk) begin
        if (reset_i) mainlatch <= 8'd0;
        else if (cen_cpu_wr && ls259_wr) mainlatch[A[2:0]] <= cpu_dout[0];
    end

    wire irq_mask     = mainlatch[0];
    wire gfx_bank     = mainlatch[2];
    // The game's own flip only; CRT Flip goes to VIDEO separately (a raster mirror on top of this)
    wire flip_screen  = ~mainlatch[3];   // latch bit is active low
    wire palette_bank = mainlatch[4];

    ////////////////////////////////////////////////////////////////////////
    // Watchdog: 16 vblanks. DSW bit 7 reads bit 2 of (16 - count), not a DIP switch (the MRA leaves it out)
    ////////////////////////////////////////////////////////////////////////

    reg [4:0] wdog_cnt = 5'd0;
    reg       vblank_d = 1'b0;
    wire      vblank_rise = video_vblank & ~vblank_d;

    // vblank_d tracks video_vblank continuously, including during reset
    always_ff @(posedge clk) begin
        vblank_d <= video_vblank;
        if (reset_i)          wdog_cnt <= 5'd0;
        else if (wdog_wr)     wdog_cnt <= 5'd0;
        // paused: video runs on but the CPU can't kick A0C0, so the count holds
        else if (vblank_rise && !pause) wdog_cnt <= wdog_cnt + 5'd1;
    end

    // Talbot: 16 vblanks without an A0C0 kick resets the CPU side (the boot spin at 003F depends on it); video keeps
    // running
    reg [3:0] wdog_rst_cnt = 4'd0;
    always_ff @(posedge clk) begin
        if (reset)                     wdog_rst_cnt <= 4'd0;
        else if (set_is_talbot && wdog_cnt == 5'h10) wdog_rst_cnt <= 4'hF;
        else if (wdog_rst_cnt != 4'd0) wdog_rst_cnt <= wdog_rst_cnt - 4'd1;
    end
    wire reset_i = reset | (wdog_rst_cnt != 4'd0);

    // wdog_cnt counts up from a kick, so it already equals (16 - down-counter)
    wire       wdog_bit2 = wdog_cnt[2];

    wire [7:0] dsw_read = {wdog_bit2, dsw[6:0]};

    ////////////////////////////////////////////////////////////////////////
    // Sprite position RAM — A060-A06F, 16 bytes, WRITE ONLY from the CPU
    ////////////////////////////////////////////////////////////////////////

    reg [7:0] spriteram [0:15];

    reg [7:0] spriteram2 [0:15];

    always_ff @(posedge clk) begin
        if (cen_cpu_wr && spram_wr)  spriteram[A[3:0]]  <= cpu_dout;
        if (cen_cpu_wr && spram2_wr) spriteram2[A[3:0]] <= cpu_dout;
    end

    ////////////////////////////////////////////////////////////////////////
    // Sprite RAMs and the main-RAM attribute window (8FF0 champbas, 8800 exctsccr) snapshotted at vsnap, so
    // sprites and background change on the same frame
    ////////////////////////////////////////////////////////////////////////

    wire        vsnap;
    wire [10:0] spr_attr_base = is_exctsccr ? 11'h000 : 11'h7F0;

    reg [7:0] spriteram_s  [0:15];
    reg [7:0] spriteram2_s [0:15];
    reg [7:0] spr_attr_live[0:15];
    reg [7:0] spr_attr_s   [0:15];

    integer si;
    always_ff @(posedge clk) begin
        // live shadow of the main-RAM sprite attribute window
        if (cen_cpu && mem_wr && cs_ram && (A[10:4] == spr_attr_base[10:4]))
            spr_attr_live[A[3:0]] <= cpu_dout;

        if (vsnap) begin
            for (si = 0; si < 16; si = si + 1) begin
                spriteram_s [si] <= spriteram [si];
                spriteram2_s[si] <= spriteram2[si];
                spr_attr_s  [si] <= spr_attr_live[si];
            end
        end
    end

    ////////////////////////////////////////////////////////////////////////
    // Main RAM 8800-8FFF (2K); the sprite attribute window is in here, not in spriteram
    ////////////////////////////////////////////////////////////////////////

    wire [7:0] ram_dout;
    wire [3:0] spr_attr_addr;
    wire [7:0] spr_attr_data;

    // Hiscore RAM windows; Talbot's table is in VRAM (copied there from ROM at boot)
    wire hs_sel_ram   = (hs_addr[15:11] == 5'b1000_1);    // 8800-8FFF main RAM
    wire hs_sel_ram7c = (hs_addr[15:10] == 6'b0111_11);   // 7C00-7FFF exctsccr
    wire hs_sel_vram  = (hs_addr[15:11] == 5'b1000_0);    // 8000-87FF tilemap
    wire [7:0] hs_ram_dout, hs_ram7c_dout;

    // every source is a registered read, so the select is delayed one clock
    reg [1:0] hs_src_r;
    always_ff @(posedge clk)
        hs_src_r <= hs_sel_ram7c ? 2'd2 : hs_sel_vram ? 2'd1 : 2'd0;

    // board RAMs = pool blocks 0-2 (3-4 belong to the video module below)
    ram_pool_pkg::pram_i_t mram_i, eram_i, r7c_i;
    ram_pool_pkg::pram_o_t mram_o, eram_o, r7c_o;
    assign {pr_i[2], pr_i[1], pr_i[0]} = {r7c_i, eram_i, mram_i};
    assign {r7c_o, eram_o, mram_o} = {pr_o[2], pr_o[1], pr_o[0]};
    assign mram_i.a_addr = 15'(A[10:0]);
    assign mram_i.a_d    = cpu_dout;
    assign mram_i.a_we   = cen_cpu_wr & mem_wr & cs_ram;
    assign mram_i.b_addr = 15'(hs_addr[10:0]);
    assign mram_i.b_d    = hs_din;
    assign mram_i.b_we   = hs_we & hs_sel_ram;
    assign ram_dout = mram_o.a_q;
    assign hs_ram_dout = mram_o.b_q;

    // registered read: same latency as the BRAM it replaced (the sprite FSM depends on it)
    reg [7:0] spr_attr_data_r;
    always_ff @(posedge clk) spr_attr_data_r <= spr_attr_s[spr_attr_addr];
    assign spr_attr_data = spr_attr_data_r;

    // Sprite position RAM read port (combinational — it is a register array)
    wire [3:0] spr_pos_addr;
    wire       spr_pos_bank;
    wire [7:0] spr_pos_data = spr_pos_bank ? spriteram2_s[spr_pos_addr]
                                           : spriteram_s[spr_pos_addr];

    ////////////////////////////////////////////////////////////////////////
    // Per-set RAM at 6000-63FF (1K): sets without an MCU
    ////////////////////////////////////////////////////////////////////////

    wire [7:0] extram_dout;

    assign eram_i.a_addr = 15'(A[9:0]);
    assign eram_i.a_d    = cpu_dout;
    assign eram_i.a_we   = cen_cpu_wr & mem_wr & cs_extram & ~set_has_mcu;
    assign eram_i.b_addr = 15'(10'd0);
    assign eram_i.b_d    = 8'd0;
    assign eram_i.b_we   = 1'b0;
    assign extram_dout = eram_o.a_q;

    ////////////////////////////////////////////////////////////////////////
    // RAM 7C00-7FFF (exctsccr / exctscc2); on the other sets that page is the mirrored AY
    ////////////////////////////////////////////////////////////////////////

    wire [7:0] ram7c_dout;

    assign r7c_i.a_addr = 15'(A[9:0]);
    assign r7c_i.a_d    = cpu_dout;
    assign r7c_i.a_we   = cen_cpu_wr & mem_wr & cs_ram7c;
    assign r7c_i.b_addr = 15'(hs_addr[9:0]);
    assign r7c_i.b_d    = hs_din;
    assign r7c_i.b_we   = hs_we & hs_sel_ram7c;
    assign ram7c_dout = r7c_o.a_q;
    assign hs_ram7c_dout = r7c_o.b_q;

    ////////////////////////////////////////////////////////////////////////
    // ALPHA MCU (pool slot mcu_0): LS259 bit 6 = start, bit 7 = bus direction; while it owns the shared RAM the
    // plain RAM above is write-disabled and reads come from the MCU. Machine cycle 96 kHz = 49.152 MHz / 512
    ////////////////////////////////////////////////////////////////////////

    wire [7:0] mcu_ext_dout;

    assign mcu_ext_dout = mcu_0_o.ext_dout;
    assign mcu_addr     = mcu_0_o.mcu_addr;

    ////////////////////////////////////////////////////////////////////////
    // champbasja fake protection
    ////////////////////////////////////////////////////////////////////////

    wire [7:0] prot_dout = (A[0] ? 8'h80 : 8'h00) | (A[6] ? 8'h19 : 8'h00);

    ////////////////////////////////////////////////////////////////////////
    // Video
    ////////////////////////////////////////////////////////////////////////

    wire [7:0] vram_dout;

    // VRAM has no spare port (port B feeds the tilemap shadow), so hiscore access borrows the CPU port
    wire        hs_vram_own   = hs_active & hs_sel_vram;
    wire [10:0] vram_addr_cpu = hs_vram_own ? hs_addr[10:0] : A[10:0];
    wire  [7:0] vram_din_cpu  = hs_vram_own ? hs_din        : cpu_dout;
    wire        vram_we_cpu   = hs_vram_own ? hs_we
                                            : (cen_cpu_wr & mem_wr & cs_vram);

    assign hs_dout = (hs_src_r == 2'd2) ? hs_ram7c_dout
                   : (hs_src_r == 2'd1) ? vram_dout
                                        : hs_ram_dout;

    ChampionBaseball_VIDEO video
    (
        .clk(clk),
        .cen_pix(cen_pix),
        .reset(reset),

        .cpu_vram_addr(vram_addr_cpu),
        .cpu_vram_din(vram_din_cpu),
        .cpu_vram_we(vram_we_cpu),
        .cpu_vram_dout(vram_dout),

        .flip_screen(flip_screen),
        .crt_flip(crt_flip),
        .vsnap(vsnap),
        .gfx_bank(gfx_bank),
        .palette_bank(palette_bank),

        .is_exctsccr(is_exctsccr),
        .is_talbot(set_is_talbot),

        .gfx_addr(gfx_addr),
        .gfx_data(gfx_data),
        .prom_addr(prom_addr),
        .prom_data(prom_data),
        .gfx_p3_addr(gfx_p3_addr),
        .gfx_p3_data(gfx_p3_data),
        .gfx3_addr(gfx3_addr),
        .gfx3_data(gfx3_data),

        .spr_pos_addr(spr_pos_addr),
        .spr_pos_bank(spr_pos_bank),
        .spr_pos_data(spr_pos_data),
        .spr_attr_addr(spr_attr_addr),
        .spr_attr_data(spr_attr_data),

        .clk_dl(clk_dl),
        .ioctl_download(ioctl_download),
        .ioctl_index(ioctl_index),
        .ioctl_addr(ioctl_addr),
        .ioctl_data(ioctl_data),
        .ioctl_wr(ioctl_wr),

        .VGA_R(video_r),
        .VGA_G(video_g),
        .VGA_B(video_b),
        .HSync(video_hsync),
        .VSync(video_vsync),
        .HBlank(video_hblank),
        .VBlank(video_vblank),

        .pr_i(pr_i[4:3]), .pr_o(pr_o[4:3])
    );

    ////////////////////////////////////////////////////////////////////////
    // CPU read mux
    ////////////////////////////////////////////////////////////////////////

    reg [7:0] cpu_din;

    always_comb begin
        if      (cs_rom)    cpu_din = rom_data;
        else if (cs_prot)   cpu_din = prot_dout;      // champbasja, before cs_extram
        else if (cs_extram) cpu_din = set_has_mcu ? mcu_ext_dout : extram_dout;
        else if (cs_ram7c)  cpu_din = ram7c_dout;
        else if (cs_vram) cpu_din = vram_dout;
        else if (cs_ram)  cpu_din = ram_dout;
        else if (io_q0)   cpu_din = p1;
        else if (io_q1)   cpu_din = p2;
        else if (io_q2)   cpu_din = dsw_read;
        else if (io_q3)   cpu_din = system;
        else              cpu_din = 8'hFF;
    end

    assign rom_addr = A[14:0];

    ////////////////////////////////////////////////////////////////////////
    // IRQ: vblank asserts IRQ0 while irq_mask is set; clearing the mask clears it
    ////////////////////////////////////////////////////////////////////////

    reg irq_pending = 1'b0;

    always_ff @(posedge clk) begin
        if (reset_i)          irq_pending <= 1'b0;
        else if (!irq_mask)   irq_pending <= 1'b0;
        else if (vblank_rise) irq_pending <= 1'b1;
    end

    wire int_n = ~(irq_pending & irq_mask);

    ////////////////////////////////////////////////////////////////////////
    // Z80
    ////////////////////////////////////////////////////////////////////////

    assign A      = z80_0_o.a;
    assign cpu_dout = z80_0_o.dout;
    assign m1_n   = z80_0_o.m1_n;
    assign mreq_n = z80_0_o.mreq_n;
    assign iorq_n = z80_0_o.iorq_n;
    assign rd_n   = z80_0_o.rd_n;
    assign wr_n   = z80_0_o.wr_n;


    // pool slot inputs (driven here, after every signal they use is declared)
    assign z80_0_i.reset_n = ~reset_i;
    assign z80_0_i.ce      = cen_cpu & ~pause;
    assign z80_0_i.int_n   = int_n;
    assign z80_0_i.nmi_n   = 1'b1;
    assign z80_0_i.di      = cpu_din;
    assign mcu_0_i.reset     = reset_i;
    assign mcu_0_i.pause     = pause;
    assign mcu_0_i.mcu_start = mainlatch[6];
    assign mcu_0_i.bus_dir   = mainlatch[7];
    assign mcu_0_i.ext_addr  = A[9:0];
    assign mcu_0_i.ext_din   = cpu_dout;
    assign mcu_0_i.ext_we    = cen_cpu_wr & mem_wr & cs_extram & set_has_mcu;
    assign mcu_0_i.mcu_data  = mcu_data;

endmodule
