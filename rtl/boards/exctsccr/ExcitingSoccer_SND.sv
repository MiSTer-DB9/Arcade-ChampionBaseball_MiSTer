//============================================================================
//
//  ExcitingSoccer_SND.sv — exctsccr/exctscc2 sound board: a separate design
//  from champbas, with 4x AY-3-8910 and 2 DACs.
//  RAM A000-A7FF; IM1 timer IRQ at 0038, NMI at 0066.
//
//============================================================================

module ExcitingSoccer_SND
(
    input                clk,            // 49.152 MHz
    input                reset,
    input                pause,

    // Soccer II: ay3 / ay4 removed, ay1 / ay2 moved in I/O space
    input                is_exctscc2,

    // ---- from the main board (A080 write)
    input         [7:0]  sound_latch,
    input                sound_latch_wr,

    // ---- audio CPU ROM (MRA index 1, 0x0000-0x8FFF)
    output       [15:0]  rom_addr,
    input         [7:0]  rom_data,

    output signed [15:0] sound_out,

    // sound Z80 (z80_1), AYs (ay_0-3) and sound RAM (pool block 5) in the dispatcher
    output chip_pool_pkg::z80r_i_t       z80_1_i,
    input  chip_pool_pkg::z80r_o_t       z80_1_o,
    output chip_pool_pkg::ayr_i_t  [3:0] ay_i,
    input  chip_pool_pkg::ay_o_t   [3:0] ay_o,
    output ram_pool_pkg::pram_i_t        pr_i,
    input  ram_pool_pkg::pram_o_t        pr_o
);

    ////////////////////////////////////////////////////////////////////////
    // Clock enables.
    //   Z80  14.318181/4 = 3.579545 MHz -> 3579545.25/49152000 * 2^24 = 1221797
    //   AY   14.318181/8 = 1.789773 MHz -> cen_z80 / 2; exctsccr's AY 1 runs from its own (VR pot) clock
    ////////////////////////////////////////////////////////////////////////

    localparam [24:0] INC_Z80 = 25'd1221797;   // -> 3579545.6 Hz  (err 0.4 Hz)
    localparam [24:0] INC_AY1 = 25'd662263;    // -> 1940003   Hz  (err 3   Hz)

    reg [24:0] acc_z80 = 25'd0;
    reg [24:0] acc_ay1 = 25'd0;
    always_ff @(posedge clk) begin
        acc_z80 <= {1'b0, acc_z80[23:0]} + INC_Z80;
        acc_ay1 <= {1'b0, acc_ay1[23:0]} + INC_AY1;
    end

    wire cen_z80 = acc_z80[24];

    reg ay_tog = 1'b0;
    always_ff @(posedge clk) if (cen_z80) ay_tog <= ~ay_tog;

    wire cen_ay  = cen_z80 & ay_tog;                    // 1.789773 MHz
    wire cen_ay1 = is_exctscc2 ? cen_ay : acc_ay1[24];  // VR pot on exctsccr

    ////////////////////////////////////////////////////////////////////////
    // Interrupts: NMI and a timer IRQ (IM1, 0038 populated, so the vector byte is unused)
    ////////////////////////////////////////////////////////////////////////

    localparam [13:0] NMI_DIV = 14'd12287;    // 12288 counts, 0-based
    localparam [19:0] IRQ_DIV = 20'd655359;   // 655360 counts, 0-based

    reg [13:0] nmi_div_cnt = 14'd0;
    reg [19:0] irq_div_cnt = 20'd0;
    wire nmi_tick = (nmi_div_cnt == 14'd0);
    wire irq_tick = (irq_div_cnt == 20'd0);

    always_ff @(posedge clk) begin
        if (reset) begin
            nmi_div_cnt <= NMI_DIV;
            irq_div_cnt <= IRQ_DIV;
        end else begin
            nmi_div_cnt <= nmi_tick ? NMI_DIV : (nmi_div_cnt - 14'd1);
            irq_div_cnt <= irq_tick ? IRQ_DIV : (irq_div_cnt - 20'd1);
        end
    end

    wire [15:0] A;
    wire  [7:0] cpu_dout;
    wire        mreq_n, iorq_n, rd_n, wr_n, m1_n;

    // Interrupt acknowledge: IORQ with M1 low (never a real I/O cycle).
    wire int_ack = cen_z80 & ~iorq_n & ~m1_n;

    reg int_n_r = 1'b1;
    always_ff @(posedge clk) begin
        if (reset)         int_n_r <= 1'b1;
        else if (irq_tick) int_n_r <= 1'b0;   // HOLD_LINE
        else if (int_ack)  int_n_r <= 1'b1;
    end

    // NMI is edge-triggered; hold low long enough for the Z80 to latch it.
    reg [3:0] nmi_cnt = 4'd0;
    always_ff @(posedge clk) begin
        if (reset)                          nmi_cnt <= 4'd0;
        else if (nmi_tick)                  nmi_cnt <= 4'hF;
        else if (cen_z80 && nmi_cnt != 4'd0) nmi_cnt <= nmi_cnt - 4'd1;
    end
    wire nmi_n_r = (nmi_cnt == 4'd0);

    ////////////////////////////////////////////////////////////////////////
    // Memory decode
    //   0000-8FFF  ROM   (36 KB: 4 x 0x2000 + 1 x 0x1000)
    ////////////////////////////////////////////////////////////////////////

    wire mem_wr = ~mreq_n & ~wr_n;

    wire cs_rom     = (A[15:12] <= 4'h8);              // 0000-8FFF
    wire cs_ram     = (A[15:11] == 5'b1010_0);         // A000-A7FF
    wire cs_dac1    = (A == 16'hC008);
    wire cs_dac2    = (A == 16'hC009);
    wire cs_latchcl = (A == 16'hC00C);
    wire cs_latchrd = (A == 16'hC00D);

    assign rom_addr = A;

    ////////////////////////////////////////////////////////////////////////
    // Sound latch: written by the main CPU at A080, read at C00D, cleared by a C00C write
    ////////////////////////////////////////////////////////////////////////

    reg [7:0] latch_reg = 8'd0;

    always_ff @(posedge clk) begin
        if (reset)                               latch_reg <= 8'd0;
        else if (sound_latch_wr)                 latch_reg <= sound_latch;
        else if (cen_z80 & mem_wr & cs_latchcl)  latch_reg <= 8'd0;
    end

    ////////////////////////////////////////////////////////////////////////
    // Two 6-bit R2R DACs, same convention as the champbas DAC: low 6 bits payload, 0x20 mid
    ////////////////////////////////////////////////////////////////////////

    reg [5:0] dac1_reg = 6'd32;
    reg [5:0] dac2_reg = 6'd32;

    always_ff @(posedge clk) begin
        if (reset) begin
            dac1_reg <= 6'd32;
            dac2_reg <= 6'd32;
        end else if (cen_z80 & mem_wr) begin
            if (cs_dac1) dac1_reg <= cpu_dout[5:0];
            if (cs_dac2) dac2_reg <= cpu_dout[5:0];
        end
    end

    wire signed [16:0] dac1_signed = ($signed({10'd0, dac1_reg}) - 17'sd32) <<< 10;
    wire signed [16:0] dac2_signed = ($signed({10'd0, dac2_reg}) - 17'sd32) <<< 10;

    ////////////////////////////////////////////////////////////////////////
    // Work RAM — A000-A7FF (2 KB)
    ////////////////////////////////////////////////////////////////////////

    wire [7:0] ram_dout;

    assign pr_i.a_addr = 15'(A[10:0]);
    assign pr_i.a_d    = cpu_dout;
    assign pr_i.a_we   = cen_z80 & mem_wr & cs_ram;
    assign pr_i.b_addr = 15'(11'd0);
    assign pr_i.b_d    = 8'd0;
    assign pr_i.b_we   = 1'b0;
    assign ram_dout = pr_o.a_q;

    ////////////////////////////////////////////////////////////////////////
    // 4 AYs in Z80 I/O space (not memory-mapped):  exctsccr | exctscc2
    //     ay1    0x82/0x83       0x8a/0x8b
    //     ay2    0x86/0x87       0x8e/0x8f
    //     ay3    0x8a/0x8b       (removed)
    //     ay4    0x8e/0x8f       (removed)
    ////////////////////////////////////////////////////////////////////////

    wire io_wr = cen_z80 & ~iorq_n & ~wr_n & m1_n;

    wire hit_82 = io_wr & (A[7:1] == 7'b1000_001);   // 0x82/0x83
    wire hit_86 = io_wr & (A[7:1] == 7'b1000_011);   // 0x86/0x87
    wire hit_8a = io_wr & (A[7:1] == 7'b1000_101);   // 0x8a/0x8b
    wire hit_8e = io_wr & (A[7:1] == 7'b1000_111);   // 0x8e/0x8f

    wire ay1_wr = is_exctscc2 ? hit_8a : hit_82;
    wire ay2_wr = is_exctscc2 ? hit_8e : hit_86;
    wire ay3_wr = is_exctscc2 ? 1'b0   : hit_8a;
    wire ay4_wr = is_exctscc2 ? 1'b0   : hit_8e;

    wire [7:0] ay1A, ay1B, ay1C, ay2A, ay2B, ay2C;
    wire [7:0] ay3A, ay3B, ay3C, ay4A, ay4B, ay4C;

    es_ay ay1 (.clk(clk), .rst_n(~reset), .cen(cen_ay1),
               .wr(ay1_wr), .a0(A[0]), .din(cpu_dout), .A(ay1A), .B(ay1B), .C(ay1C),
               .ay_i(ay_i[0]), .ay_o(ay_o[0]));
    es_ay ay2 (.clk(clk), .rst_n(~reset), .cen(cen_ay),
               .wr(ay2_wr), .a0(A[0]), .din(cpu_dout), .A(ay2A), .B(ay2B), .C(ay2C),
               .ay_i(ay_i[1]), .ay_o(ay_o[1]));
    es_ay ay3 (.clk(clk), .rst_n(~reset), .cen(cen_ay),
               .wr(ay3_wr), .a0(A[0]), .din(cpu_dout), .A(ay3A), .B(ay3B), .C(ay3C),
               .ay_i(ay_i[2]), .ay_o(ay_o[2]));
    es_ay ay4 (.clk(clk), .rst_n(~reset), .cen(cen_ay),
               .wr(ay4_wr), .a0(A[0]), .din(cpu_dout), .A(ay4A), .B(ay4B), .C(ay4C),
               .ay_i(ay_i[3]), .ay_o(ay_o[3]));

    ////////////////////////////////////////////////////////////////////////
    // DC removal — same shaping as the champbas board (raw byte into bit 5).
    ////////////////////////////////////////////////////////////////////////

    reg div = 1'b0;
    always_ff @(posedge clk) div <= ~div;
    wire cen_dcrm = ~div;

    wire signed [15:0] d1A, d1B, d1C, d2A, d2B, d2C;
    wire signed [15:0] d3A, d3B, d3C, d4A, d4B, d4C;

    jt49_dcrm2 #(16) r1A (.clk(clk), .cen(cen_dcrm), .rst(reset), .din({3'd0, ay1A, 5'd0}), .dout(d1A));
    jt49_dcrm2 #(16) r1B (.clk(clk), .cen(cen_dcrm), .rst(reset), .din({3'd0, ay1B, 5'd0}), .dout(d1B));
    jt49_dcrm2 #(16) r1C (.clk(clk), .cen(cen_dcrm), .rst(reset), .din({3'd0, ay1C, 5'd0}), .dout(d1C));
    jt49_dcrm2 #(16) r2A (.clk(clk), .cen(cen_dcrm), .rst(reset), .din({3'd0, ay2A, 5'd0}), .dout(d2A));
    jt49_dcrm2 #(16) r2B (.clk(clk), .cen(cen_dcrm), .rst(reset), .din({3'd0, ay2B, 5'd0}), .dout(d2B));
    jt49_dcrm2 #(16) r2C (.clk(clk), .cen(cen_dcrm), .rst(reset), .din({3'd0, ay2C, 5'd0}), .dout(d2C));
    jt49_dcrm2 #(16) r3A (.clk(clk), .cen(cen_dcrm), .rst(reset), .din({3'd0, ay3A, 5'd0}), .dout(d3A));
    jt49_dcrm2 #(16) r3B (.clk(clk), .cen(cen_dcrm), .rst(reset), .din({3'd0, ay3B, 5'd0}), .dout(d3B));
    jt49_dcrm2 #(16) r3C (.clk(clk), .cen(cen_dcrm), .rst(reset), .din({3'd0, ay3C, 5'd0}), .dout(d3C));
    jt49_dcrm2 #(16) r4A (.clk(clk), .cen(cen_dcrm), .rst(reset), .din({3'd0, ay4A, 5'd0}), .dout(d4A));
    jt49_dcrm2 #(16) r4B (.clk(clk), .cen(cen_dcrm), .rst(reset), .din({3'd0, ay4B, 5'd0}), .dout(d4B));
    jt49_dcrm2 #(16) r4C (.clk(clk), .cen(cen_dcrm), .rst(reset), .din({3'd0, ay4C, 5'd0}), .dout(d4C));

    ////////////////////////////////////////////////////////////////////////
    // Mix: each AY 0.08, each DAC 0.3 of the output (approximated with shifts below)
    ////////////////////////////////////////////////////////////////////////

    wire signed [19:0] ay_sum = {{4{d1A[15]}}, d1A} + {{4{d1B[15]}}, d1B} + {{4{d1C[15]}}, d1C}
                              + {{4{d2A[15]}}, d2A} + {{4{d2B[15]}}, d2B} + {{4{d2C[15]}}, d2C}
                              + {{4{d3A[15]}}, d3A} + {{4{d3B[15]}}, d3B} + {{4{d3C[15]}}, d3C}
                              + {{4{d4A[15]}}, d4A} + {{4{d4B[15]}}, d4B} + {{4{d4C[15]}}, d4C};

    wire signed [19:0] dac_sum = {{3{dac1_signed[16]}}, dac1_signed}
                               + {{3{dac2_signed[16]}}, dac2_signed};

    wire signed [19:0] mix = (dac_sum >>> 2) + (dac_sum >>> 4)   // DAC x 0.3125
                           + (ay_sum  >>> 2);                    // AY  x 0.25

    assign sound_out = pause ? 16'sd0 : mix[15:0];

    ////////////////////////////////////////////////////////////////////////
    // CPU read mux + Z80
    ////////////////////////////////////////////////////////////////////////

    reg [7:0] cpu_din;

    always_comb begin
        if      (cs_rom)     cpu_din = rom_data;
        else if (cs_ram)     cpu_din = ram_dout;
        else if (cs_latchrd) cpu_din = latch_reg;
        else                 cpu_din = 8'hFF;
    end

    assign A      = z80_1_o.a;
    assign cpu_dout = z80_1_o.dout;
    assign m1_n   = z80_1_o.m1_n;
    assign mreq_n = z80_1_o.mreq_n;
    assign iorq_n = z80_1_o.iorq_n;
    assign rd_n   = z80_1_o.rd_n;
    assign wr_n   = z80_1_o.wr_n;

    // pool slot inputs (driven here, after every signal they use is declared)
    assign z80_1_i.reset_n = ~reset;
    assign z80_1_i.ce      = cen_z80 & ~pause;
    assign z80_1_i.int_n   = int_n_r;
    assign z80_1_i.nmi_n   = nmi_n_r;
    assign z80_1_i.di      = cpu_din;

endmodule

//============================================================================
//  One AY-3-8910 with a stretched write strobe.
//  The strobe is held until the next AY clock enable (a Z80 write is shorter than an AY cycle).
//============================================================================

module es_ay
(
    input        clk,
    input        rst_n,
    input        cen,
    input        wr,          // already gated by cen_z80
    input        a0,          // 0 = data write, 1 = address latch
    input  [7:0] din,
    output [7:0] A,
    output [7:0] B,
    output [7:0] C,
    output chip_pool_pkg::ayr_i_t ay_i,   // the AY itself is a dispatcher pool slot
    input  chip_pool_pkg::ay_o_t  ay_o
);

    reg       pending = 1'b0;
    reg       bc1_lat = 1'b0;
    reg [7:0] din_lat = 8'd0;

    always_ff @(posedge clk) begin
        if (!rst_n) pending <= 1'b0;
        else if (wr) begin
            pending <= 1'b1;
            bc1_lat <= a0;      // address latch = bc1 high
            din_lat <= din;
        end else if (cen) pending <= 1'b0;
    end

    assign ay_i.rst_n  = rst_n;
    assign ay_i.ce     = cen;
    assign ay_i.bdir   = pending;
    assign ay_i.bc1    = bc1_lat;
    assign ay_i.din    = din_lat;
    assign ay_i.ioa_in = 8'hFF;
    assign ay_i.iob_in = 8'hFF;
    assign A = ay_o.a;
    assign B = ay_o.b;
    assign C = ay_o.c;

endmodule
