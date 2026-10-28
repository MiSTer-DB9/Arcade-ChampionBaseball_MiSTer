//============================================================================
//
//  ChampionBaseball_SND.sv - champbas sound board: Z80 driving a 6-bit DAC. The AY is on the main board
//  (written by the main CPU); this CPU never sees it, the AY is mixed here.
//
//============================================================================

module ChampionBaseball_SND
(
    input                clk,
    input                cen_cpu,        // 3.072 MHz
    input                cen_ay,         // 1.536 MHz
    input                reset,
    input                pause,

    // ---- from the main board
    input         [7:0]  sound_latch,
    input                sound_latch_wr,
    input         [7:0]  ay_din,
    input                ay_addr_wr,
    input                ay_data_wr,

    // ---- audio CPU ROM (champbas_rom index 1)
    output       [15:0]  rom_addr,
    input         [7:0]  rom_data,

    output signed [15:0] sound_out,

    // sound Z80 (z80_1), AY (ay_0) and sound RAM (pool block 5) in the dispatcher
    output chip_pool_pkg::z80r_i_t z80_1_i,
    input  chip_pool_pkg::z80r_o_t z80_1_o,
    output chip_pool_pkg::ayr_i_t  ay_0_i,
    input  chip_pool_pkg::ay_o_t   ay_0_o,
    output ram_pool_pkg::pram_i_t  pr_i,
    input  ram_pool_pkg::pram_o_t  pr_o
);

    ////////////////////////////////////////////////////////////////////////
    // Address decode (8K pages; the stack at E3FF confirms RAM at E000)
    ////////////////////////////////////////////////////////////////////////

    wire [15:0] A;
    wire  [7:0] cpu_dout;
    wire        mreq_n, iorq_n, rd_n, wr_n, m1_n;

    wire mem_wr = ~mreq_n & ~wr_n;

    wire cs_rom   = (A[15:13] <  3'b011);   // 0000-5FFF
    wire cs_latch = (A[15:13] == 3'b011);   // 6000-7FFF
    wire cs_ret   = (A[15:13] == 3'b100);   // 8000-9FFF (write-only, ignored)
    wire cs_clr   = (A[15:13] == 3'b101);   // A000-BFFF
    wire cs_dac   = (A[15:13] == 3'b110);   // C000-DFFF
    wire cs_ram   = (A[15:13] == 3'b111);   // E000-FFFF

    assign rom_addr = A;

    ////////////////////////////////////////////////////////////////////////
    // Sound latch
    ////////////////////////////////////////////////////////////////////////

    reg [7:0] latch_reg = 8'd0;

    always_ff @(posedge clk) begin
        if (reset)                          latch_reg <= 8'd0;
        else if (sound_latch_wr)            latch_reg <= sound_latch;
        else if (cen_cpu & mem_wr & cs_clr) latch_reg <= 8'd0;
    end

    ////////////////////////////////////////////////////////////////////////
    // 6-bit R2R DAC at C000; 0x20 = mid-scale (the program sets it at boot)
    ////////////////////////////////////////////////////////////////////////

    reg [5:0] dac_reg = 6'd32;

    always_ff @(posedge clk) begin
        if (reset)                          dac_reg <= 6'd32;
        else if (cen_cpu & mem_wr & cs_dac) dac_reg <= cpu_dout[5:0];
    end

    // Centre on mid-scale, then scale to FULL 16-bit range: (-32..+31) << 10
    wire signed [16:0] dac_signed = ($signed({10'd0, dac_reg}) - 17'sd32) <<< 10;

    ////////////////////////////////////////////////////////////////////////
    // Work RAM — E000-E3FF (1KB)
    ////////////////////////////////////////////////////////////////////////

    wire [7:0] ram_dout;

    assign pr_i.a_addr = 15'(A[9:0]);
    assign pr_i.a_d    = cpu_dout;
    assign pr_i.a_we   = cen_cpu & mem_wr & cs_ram;
    assign pr_i.b_addr = 15'(10'd0);
    assign pr_i.b_d    = 8'd0;
    assign pr_i.b_we   = 1'b0;
    assign ram_dout = pr_o.a_q;

    ////////////////////////////////////////////////////////////////////////
    // AY-3-8910 (pool slot ay_0): 7000 = data, 7001 = address (address latch = BDIR/BC1 11, data = 10).
    // The strobe is stretched to the next AY clock enable: the Z80 write pulse is shorter than an AY cycle
    ////////////////////////////////////////////////////////////////////////

    reg        ay_pending = 1'b0;
    reg        ay_bc1_lat = 1'b0;
    reg  [7:0] ay_din_lat = 8'd0;

    always_ff @(posedge clk) begin
        if (reset) ay_pending <= 1'b0;
        else if (ay_addr_wr | ay_data_wr) begin
            ay_pending <= 1'b1;
            ay_bc1_lat <= ay_addr_wr;      // address latch = bc1 high
            ay_din_lat <= ay_din;
        end else if (cen_ay) ay_pending <= 1'b0;
    end

    wire [7:0] ayA_raw, ayB_raw, ayC_raw;

    assign ayA_raw = ay_0_o.a;
    assign ayB_raw = ay_0_o.b;
    assign ayC_raw = ay_0_o.c;

    // DC removal, same shaping as TimePilot: raw byte shifted up into 16 bits
    reg div = 1'b0;
    always_ff @(posedge clk) div <= ~div;
    wire cen_dcrm = ~div;

    wire signed [15:0] ayA_dc, ayB_dc, ayC_dc;

    jt49_dcrm2 #(16) dcrm_A
    ( .clk(clk), .cen(cen_dcrm), .rst(reset), .din({3'd0, ayA_raw, 5'd0}), .dout(ayA_dc) );
    jt49_dcrm2 #(16) dcrm_B
    ( .clk(clk), .cen(cen_dcrm), .rst(reset), .din({3'd0, ayB_raw, 5'd0}), .dout(ayB_dc) );
    jt49_dcrm2 #(16) dcrm_C
    ( .clk(clk), .cen(cen_dcrm), .rst(reset), .din({3'd0, ayC_raw, 5'd0}), .dout(ayC_dc) );

    ////////////////////////////////////////////////////////////////////////
    // Mix: AY 0.3, DAC 0.7 of the output (approximated with shifts below)
    ////////////////////////////////////////////////////////////////////////

    wire signed [17:0] ay_sum = {{2{ayA_dc[15]}}, ayA_dc}
                              + {{2{ayB_dc[15]}}, ayB_dc}
                              + {{2{ayC_dc[15]}}, ayC_dc};

    wire signed [17:0] dac_x  = {dac_signed[16], dac_signed};

    wire signed [17:0] mix = (dac_x  >>> 1) + (dac_x  >>> 2)     // DAC x 0.75
                           + (ay_sum >>> 1) + (ay_sum >>> 3);    // AY  x 0.625

    assign sound_out = pause ? 16'sd0 : mix[15:0];

    ////////////////////////////////////////////////////////////////////////
    // CPU read mux + Z80
    ////////////////////////////////////////////////////////////////////////

    reg [7:0] cpu_din;

    always_comb begin
        if      (cs_rom)   cpu_din = rom_data;
        else if (cs_latch) cpu_din = latch_reg;
        else if (cs_ram)   cpu_din = ram_dout;
        else               cpu_din = 8'hFF;
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
    assign z80_1_i.ce      = cen_cpu & ~pause;
    assign z80_1_i.int_n   = 1'b1;
    assign z80_1_i.nmi_n   = 1'b1;
    assign z80_1_i.di      = cpu_din;
    assign ay_0_i.rst_n  = ~reset;
    assign ay_0_i.ce     = cen_ay;
    assign ay_0_i.bdir   = ay_pending;
    assign ay_0_i.bc1    = ay_bc1_lat;
    assign ay_0_i.din    = ay_din_lat;
    assign ay_0_i.ioa_in = 8'hFF;
    assign ay_0_i.iob_in = 8'hFF;

endmodule
