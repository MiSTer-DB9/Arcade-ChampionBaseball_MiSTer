
module ChampionBaseball_MAIN
(
    input                clk,
    input                cen_cpu,
    input                cen_pix,
    input                reset,
    input                pause,

    input         [7:0]  p1,
    input         [7:0]  p2,
    input         [7:0]  dsw,
    input         [7:0]  system,

    input         [7:0]  set_id,

    input        [15:0]  hs_addr,
    input         [7:0]  hs_din,
    output        [7:0]  hs_dout,
    input                hs_we,
    input                hs_active,

    input                crt_flip,

    output       [12:0]  mcu_addr,
    input         [7:0]  mcu_data,

    output       [14:0]  rom_addr,
    input         [7:0]  rom_data,

    output       [13:0]  gfx_addr,
    input         [7:0]  gfx_data,
    output        [9:0]  prom_addr,
    input         [7:0]  prom_data,

    output       [12:0]  gfx_p3_addr,
    input         [7:0]  gfx_p3_data,

    output       [12:0]  gfx3_addr,
    input         [7:0]  gfx3_data,

    output        [7:0]  ay_din,
    output               ay_addr_wr,
    output               ay_data_wr,

    output        [7:0]  sound_latch,
    output               sound_latch_wr,

    input                clk_dl,
    input                ioctl_download,
    input         [7:0]  ioctl_index,
    input        [24:0]  ioctl_addr,
    input         [7:0]  ioctl_data,
    input                ioctl_wr,

    output        [7:0]  video_r, video_g, video_b,
    output               video_hsync, video_vsync,
    output               video_hblank, video_vblank,

    output chip_pool_pkg::z80r_i_t      z80_0_i,
    input  chip_pool_pkg::z80r_o_t      z80_0_o,
    output chip_pool_pkg::alpha8201_i_t mcu_0_i,
    input  chip_pool_pkg::alpha8201_o_t mcu_0_o,
    output ram_pool_pkg::pram_i_t [4:0] pr_i,
    input  ram_pool_pkg::pram_o_t [4:0] pr_o
);

    wire [15:0] A;
    wire  [7:0] cpu_dout;
    wire        m1_n, mreq_n, iorq_n, rd_n, wr_n;

    wire set_has_extram = (set_id == 8'h01) || (set_id == 8'h02) || (set_id == 8'h03)
                       || (set_id == 8'h04) || (set_id == 8'h05)
                       || (set_id == 8'h07)
                       || ((set_id >= 8'h08) && (set_id <= 8'h0A));

    wire set_has_mcu    = (set_id == 8'h01) || (set_id == 8'h04) || (set_id == 8'h05)
                       || (set_id == 8'h07)
                       || (set_id == 8'h08) || (set_id == 8'h09);
    wire set_has_prot   = (set_id == 8'h02);

    wire set_is_exctsccr_full = (set_id == 8'h08) || (set_id == 8'h09);

    wire set_is_talbot = (set_id == 8'h07);

    wire cs_extram = set_has_extram && (A[15:10] == 6'b0110_00);
    wire cs_prot   = set_has_prot   && (A[15:8]  == 8'h68);
    wire cs_ram7c  = set_is_exctsccr_full && (A[15:10] == 6'b0111_11);

    wire set_has_rom78 = (set_id == 8'h04) || (set_id == 8'h05);
    wire cs_rom78 = set_has_rom78 && (A[15:11] == 5'b0111_1);
    wire cs_rom   = (A <  16'h6000) || cs_rom78;
    wire cs_ay    = (A[15:12] == 4'h7) && !set_is_exctsccr_full && !cs_rom78;
    wire cs_vram  = (A[15:11] == 5'b1000_0);
    wire cs_ram   = (A[15:11] == 5'b1000_1);
    wire cs_io    = (A[15:8]  == 8'hA0);

    wire cen_cpu_wr = cen_cpu & ~pause;

    wire mem_rd = ~mreq_n & ~rd_n;
    wire mem_wr = ~mreq_n & ~wr_n;

    wire io_q0 = cs_io & (A[7:6] == 2'b00);
    wire io_q1 = cs_io & (A[7:6] == 2'b01);
    wire io_q2 = cs_io & (A[7:6] == 2'b10);
    wire io_q3 = cs_io & (A[7:6] == 2'b11);

    wire ls259_wr   = mem_wr & io_q0 & (A[5:3] == 3'b000);
    wire spram_wr   = mem_wr & io_q1 & (A[5:4] == 2'b10);
    wire spram2_wr  = mem_wr & io_q1 & (A[5:4] == 2'b00);
    assign sound_latch_wr = mem_wr & io_q2;
    wire wdog_wr    = mem_wr & io_q3;

    assign sound_latch = cpu_dout;

    localparam SET_CHAMPBB2J = 8'h05;

    wire is_exctsccr = (set_id >= 8'h08) && (set_id <= 8'h0A);

    wire ay_sel_inverted = (set_id == SET_CHAMPBB2J);
    wire ay_wr           = mem_wr & cs_ay;
    wire ay_is_addr      = ay_sel_inverted ? ~A[0] : A[0];

    assign ay_din     = cpu_dout;
    assign ay_addr_wr = ay_wr &  ay_is_addr;
    assign ay_data_wr = ay_wr & ~ay_is_addr;

    reg [7:0] mainlatch = 8'd0;

    always_ff @(posedge clk) begin
        if (reset_i) mainlatch <= 8'd0;
        else if (cen_cpu_wr && ls259_wr) mainlatch[A[2:0]] <= cpu_dout[0];
    end

    wire irq_mask     = mainlatch[0];
    wire gfx_bank     = mainlatch[2];
    wire flip_screen  = ~mainlatch[3];
    wire palette_bank = mainlatch[4];

    reg [4:0] wdog_cnt = 5'd0;
    reg       vblank_d = 1'b0;
    wire      vblank_rise = video_vblank & ~vblank_d;

    always_ff @(posedge clk) begin
        vblank_d <= video_vblank;
        if (reset_i)          wdog_cnt <= 5'd0;
        else if (wdog_wr)     wdog_cnt <= 5'd0;
        else if (vblank_rise && !pause) wdog_cnt <= wdog_cnt + 5'd1;
    end

    reg [3:0] wdog_rst_cnt = 4'd0;
    always_ff @(posedge clk) begin
        if (reset)                     wdog_rst_cnt <= 4'd0;
        else if (set_is_talbot && wdog_cnt == 5'h10) wdog_rst_cnt <= 4'hF;
        else if (wdog_rst_cnt != 4'd0) wdog_rst_cnt <= wdog_rst_cnt - 4'd1;
    end
    wire reset_i = reset | (wdog_rst_cnt != 4'd0);

    wire       wdog_bit2 = wdog_cnt[2];

    wire [7:0] dsw_read = {wdog_bit2, dsw[6:0]};

    reg [7:0] spriteram [0:15];

    reg [7:0] spriteram2 [0:15];

    always_ff @(posedge clk) begin
        if (cen_cpu_wr && spram_wr)  spriteram[A[3:0]]  <= cpu_dout;
        if (cen_cpu_wr && spram2_wr) spriteram2[A[3:0]] <= cpu_dout;
    end

    wire        vsnap;
    wire [10:0] spr_attr_base = is_exctsccr ? 11'h000 : 11'h7F0;

    reg [7:0] spriteram_s  [0:15];
    reg [7:0] spriteram2_s [0:15];
    reg [7:0] spr_attr_live[0:15];
    reg [7:0] spr_attr_s   [0:15];

    integer si;
    always_ff @(posedge clk) begin
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

    wire [7:0] ram_dout;
    wire [3:0] spr_attr_addr;
    wire [7:0] spr_attr_data;

    wire hs_sel_ram   = (hs_addr[15:11] == 5'b1000_1);
    wire hs_sel_ram7c = (hs_addr[15:10] == 6'b0111_11);
    wire hs_sel_vram  = (hs_addr[15:11] == 5'b1000_0);
    wire [7:0] hs_ram_dout, hs_ram7c_dout;

    reg [1:0] hs_src_r;
    always_ff @(posedge clk)
        hs_src_r <= hs_sel_ram7c ? 2'd2 : hs_sel_vram ? 2'd1 : 2'd0;

    ram_pool_pkg::pram_i_t mram_i, eram_i, r7c_i;
    ram_pool_pkg::pram_o_t mram_o, eram_o, r7c_o;
    assign {pr_i[2], pr_i[1], pr_i[0]} = {r7c_i, eram_i, mram_i};
    assign {r7c_o, eram_o, mram_o} = {pr_o[2], pr_o[1], pr_o[0]};
    assign mram_i.a_addr = 16'(A[10:0]);
    assign mram_i.a_d    = cpu_dout;
    assign mram_i.a_we   = cen_cpu_wr & mem_wr & cs_ram;
    assign mram_i.b_addr = 16'(hs_addr[10:0]);
    assign mram_i.b_d    = hs_din;
    assign mram_i.b_we   = hs_we & hs_sel_ram;
    assign ram_dout = mram_o.a_q;
    assign hs_ram_dout = mram_o.b_q;

    reg [7:0] spr_attr_data_r;
    always_ff @(posedge clk) spr_attr_data_r <= spr_attr_s[spr_attr_addr];
    assign spr_attr_data = spr_attr_data_r;

    wire [3:0] spr_pos_addr;
    wire       spr_pos_bank;
    wire [7:0] spr_pos_data = spr_pos_bank ? spriteram2_s[spr_pos_addr]
                                           : spriteram_s[spr_pos_addr];

    wire [7:0] extram_dout;

    assign eram_i.a_addr = 16'(A[9:0]);
    assign eram_i.a_d    = cpu_dout;
    assign eram_i.a_we   = cen_cpu_wr & mem_wr & cs_extram & ~set_has_mcu;
    assign eram_i.b_addr = 16'(10'd0);
    assign eram_i.b_d    = 8'd0;
    assign eram_i.b_we   = 1'b0;
    assign extram_dout = eram_o.a_q;

    wire [7:0] ram7c_dout;

    assign r7c_i.a_addr = 16'(A[9:0]);
    assign r7c_i.a_d    = cpu_dout;
    assign r7c_i.a_we   = cen_cpu_wr & mem_wr & cs_ram7c;
    assign r7c_i.b_addr = 16'(hs_addr[9:0]);
    assign r7c_i.b_d    = hs_din;
    assign r7c_i.b_we   = hs_we & hs_sel_ram7c;
    assign ram7c_dout = r7c_o.a_q;
    assign hs_ram7c_dout = r7c_o.b_q;

    wire [7:0] mcu_ext_dout;

    assign mcu_ext_dout = mcu_0_o.ext_dout;
    assign mcu_addr     = mcu_0_o.mcu_addr;

    wire [7:0] prot_dout = (A[0] ? 8'h80 : 8'h00) | (A[6] ? 8'h19 : 8'h00);

    wire [7:0] vram_dout;

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

    reg [7:0] cpu_din;

    always_comb begin
        if      (cs_rom)    cpu_din = rom_data;
        else if (cs_prot)   cpu_din = prot_dout;
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

    reg irq_pending = 1'b0;

    always_ff @(posedge clk) begin
        if (reset_i)          irq_pending <= 1'b0;
        else if (!irq_mask)   irq_pending <= 1'b0;
        else if (vblank_rise) irq_pending <= 1'b1;
    end

    wire int_n = ~(irq_pending & irq_mask);

    assign A      = z80_0_o.a;
    assign cpu_dout = z80_0_o.dout;
    assign m1_n   = z80_0_o.m1_n;
    assign mreq_n = z80_0_o.mreq_n;
    assign iorq_n = z80_0_o.iorq_n;
    assign rd_n   = z80_0_o.rd_n;
    assign wr_n   = z80_0_o.wr_n;

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
