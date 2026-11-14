
module ChampionBaseball_VIDEO
(
    input               clk,
    input               cen_pix,
    input               reset,

    input       [10:0]  cpu_vram_addr,
    input        [7:0]  cpu_vram_din,
    input               cpu_vram_we,
    output       [7:0]  cpu_vram_dout,

    input               flip_screen,
    input               crt_flip,

    output              vsnap,
    input               gfx_bank,
    input               palette_bank,

    input               is_exctsccr,
    input               is_talbot,

    output      [13:0]  gfx_addr,
    input        [7:0]  gfx_data,

    output      [12:0]  gfx_p3_addr,
    input        [7:0]  gfx_p3_data,

    output       [9:0]  prom_addr,
    input        [7:0]  prom_data,

    output       [3:0]  spr_pos_addr,
    output              spr_pos_bank,   // 0 = spriteram $A060, 1 = spriteram2 $A040
    input        [7:0]  spr_pos_data,
    output       [3:0]  spr_attr_addr,
    input        [7:0]  spr_attr_data,

    output      [12:0]  gfx3_addr,
    input        [7:0]  gfx3_data,

    input               clk_dl,
    input               ioctl_download,
    input        [7:0]  ioctl_index,
    input       [24:0]  ioctl_addr,
    input        [7:0]  ioctl_data,
    input               ioctl_wr,

    output       [7:0]  VGA_R,
    output       [7:0]  VGA_G,
    output       [7:0]  VGA_B,
    output              HSync,
    output              VSync,
    output              HBlank,
    output              VBlank,

    output ram_pool_pkg::pram_i_t [1:0] pr_i,
    input  ram_pool_pkg::pram_o_t [1:0] pr_o
);

    localparam H_TOTAL   = 9'd384;
    localparam H_VIS     = 9'd256;
    localparam HS_START  = 9'd272;
    localparam HS_END    = 9'd304;

    localparam V_TOTAL   = 9'd264;
    localparam V_VIS_LO  = 9'd16;
    localparam V_VIS_HI  = 9'd240;
    localparam VS_START  = 9'd244;
    localparam VS_END    = 9'd248;

    reg [8:0] h_cnt = 9'd0;
    reg [8:0] v_cnt = 9'd0;

    always_ff @(posedge clk) begin
        if (reset) begin
            h_cnt <= 9'd0;
            v_cnt <= 9'd0;
        end else if (cen_pix) begin
            if (h_cnt == H_TOTAL - 9'd1) begin
                h_cnt <= 9'd0;
                v_cnt <= (v_cnt == V_TOTAL - 9'd1) ? 9'd0 : v_cnt + 9'd1;
            end else begin
                h_cnt <= h_cnt + 9'd1;
            end
        end
    end

    wire hblk = (h_cnt >= H_VIS);
    wire vblk = (v_cnt < V_VIS_LO) || (v_cnt >= V_VIS_HI);

    assign HBlank = hblk;
    assign VBlank = vblk;
    assign HSync  = (h_cnt >= HS_START) && (h_cnt < HS_END);
    assign VSync  = (v_cnt >= VS_START) && (v_cnt < VS_END);

    wire [7:0] h_raw = h_cnt[7:0];
    wire [7:0] v_raw = v_cnt[7:0];

    wire       flip_scan = flip_screen ^ crt_flip;
    wire [7:0] sx = h_raw ^ {8{flip_scan}};
    wire [7:0] sy = v_raw ^ {8{flip_scan}};

    wire [4:0] tile_col = sx[7:3];
    wire [4:0] tile_row = sy[7:3];
    wire [2:0] fx       = sx[2:0];
    wire [2:0] fy       = sy[2:0];

    reg  [10:0] vram_raddr;
    wire  [7:0] vram_rdata;
    wire [10:0] vram_addr_mux;

    wire       snap_trig = (v_cnt == 9'd12) && (h_cnt == 9'd0);
    reg        snap_d;
    always_ff @(posedge clk) snap_d <= snap_trig;
    wire       snap_pulse = snap_trig & ~snap_d;
    assign     vsnap = snap_pulse;

    reg [11:0] cp_cnt;
    reg        cp_run;
    reg [10:0] cp_addr_d;
    reg        cp_we_d;
    wire [7:0] cp_data;

    always_ff @(posedge clk) begin
        if (snap_pulse) begin
            cp_cnt <= 12'd0;
            cp_run <= 1'b1;
        end else if (cp_run) begin
            if (cp_cnt == 12'd2047) cp_run <= 1'b0;
            cp_cnt <= cp_cnt + 12'd1;
        end
        cp_addr_d <= cp_cnt[10:0];
        cp_we_d   <= cp_run;
    end

    ram_pool_pkg::pram_i_t tram_i, tsh_i;
    ram_pool_pkg::pram_o_t tram_o, tsh_o;
    assign pr_i = {tsh_i, tram_i};
    assign {tsh_o, tram_o} = pr_o;
    assign tram_i.a_addr = 16'(cpu_vram_addr);
    assign tram_i.a_d    = cpu_vram_din;
    assign tram_i.a_we   = cpu_vram_we;
    assign tram_i.b_addr = 16'(cp_cnt[10:0]);
    assign tram_i.b_d    = 8'd0;
    assign tram_i.b_we   = 1'b0;
    assign cpu_vram_dout = tram_o.a_q;
    assign cp_data = tram_o.b_q;

    assign tsh_i.a_addr = 16'(cp_addr_d);
    assign tsh_i.a_d    = cp_data;
    assign tsh_i.a_we   = cp_we_d;
    assign tsh_i.b_addr = 16'(vram_addr_mux);
    assign tsh_i.b_d    = 8'd0;
    assign tsh_i.b_we   = 1'b0;
    assign vram_rdata = tsh_o.b_q;

    wire [7:0] sy_next       = (v_raw + 8'd1) ^ {8{flip_scan}};
    wire [4:0] tile_row_next = sy_next[7:3];
    wire [2:0] fy_next       = sy_next[2:0];

    wire       prime         = (h_cnt >= 9'd376);

    wire [2:0] ph = h_cnt[2:0];

    wire [4:0] fetch_col = flip_scan ? (tile_col - 5'd1) : (tile_col + 5'd1);

    wire [4:0] prime_col = flip_scan ? 5'd31 : 5'd0;

    reg  [7:0] code_nxt;
    reg  [4:0] color_nxt;
    reg  [7:0] byte_lo_nxt, byte_hi_nxt;

    reg  [4:0] color_lat;
    reg  [7:0] byte_lo_lat, byte_hi_lat;

    reg  [3:0] p2_hi_nxt, p2_lo_nxt, p2_hi_lat, p2_lo_lat;
    reg        p2_hi_nib, p2_lo_nib;
    reg [12:0] gfx_p3_addr_r;
    assign gfx_p3_addr = spr_busy ? spr_p3_addr : gfx_p3_addr_r;

    reg [13:0] gfx_addr_r;
    assign gfx_addr    = spr_busy ? spr_gfx_addr : gfx_addr_r;

    wire [8:0] code_full = {gfx_bank, code_nxt};

    always_ff @(posedge clk) begin
        if (cen_pix) begin
            if (prime) begin
                case (h_cnt)
                    9'd376: vram_raddr <= {1'b0, tile_row_next, prime_col};
                    9'd377: begin
                        code_nxt   <= vram_rdata;
                        vram_raddr <= {1'b1, tile_row_next, prime_col};
                    end
                    9'd378: begin
                        color_nxt  <= vram_rdata[4:0];
                        gfx_addr_r <= {1'b0, code_full, 1'b1, fy_next};
                        gfx_p3_addr_r <= {1'b0, code_full[7:0], 1'b1, fy_next};
                        p2_hi_nib  <= code_full[8];
                    end
                    9'd379: begin
                        byte_hi_nxt <= gfx_data;
                        p2_hi_nxt   <= p2_hi_nib ? gfx_p3_data[7:4] : gfx_p3_data[3:0];
                        gfx_addr_r  <= {1'b0, code_full, 1'b0, fy_next};
                        gfx_p3_addr_r <= {1'b0, code_full[7:0], 1'b0, fy_next};
                        p2_lo_nib   <= code_full[8];
                    end
                    9'd380: begin
                        byte_lo_nxt <= gfx_data;
                        p2_lo_nxt   <= p2_lo_nib ? gfx_p3_data[7:4] : gfx_p3_data[3:0];
                    end
                    9'd383: begin
                        color_lat   <= color_nxt;
                        byte_lo_lat <= byte_lo_nxt;
                        byte_hi_lat <= byte_hi_nxt;
                        p2_lo_lat   <= p2_lo_nxt;
                        p2_hi_lat   <= p2_hi_nxt;
                    end
                    default: ;
                endcase
            end else
            case (ph)
                3'd0: vram_raddr <= {1'b0, tile_row, fetch_col};
                3'd1: begin
                    code_nxt   <= vram_rdata;
                    vram_raddr <= {1'b1, tile_row, fetch_col};
                end
                3'd2: begin
                    color_nxt   <= vram_rdata[4:0];
                    gfx_addr_r  <= {1'b0, code_full, 1'b1, fy};
                    gfx_p3_addr_r <= {1'b0, code_full[7:0], 1'b1, fy};
                    p2_hi_nib   <= code_full[8];
                end
                3'd3: begin
                    byte_hi_nxt <= gfx_data;
                    p2_hi_nxt   <= p2_hi_nib ? gfx_p3_data[7:4] : gfx_p3_data[3:0];
                    gfx_addr_r  <= {1'b0, code_full, 1'b0, fy};
                    gfx_p3_addr_r <= {1'b0, code_full[7:0], 1'b0, fy};
                    p2_lo_nib   <= code_full[8];
                end
                3'd4: begin
                    byte_lo_nxt <= gfx_data;
                    p2_lo_nxt   <= p2_lo_nib ? gfx_p3_data[7:4] : gfx_p3_data[3:0];
                end
                3'd7: begin
                    color_lat   <= color_nxt;
                    byte_lo_lat <= byte_lo_nxt;
                    byte_hi_lat <= byte_hi_nxt;
                    p2_lo_lat   <= p2_lo_nxt;
                    p2_hi_lat   <= p2_hi_nxt;
                end
                default: ;
            endcase
        end
    end

    wire [7:0] byte_sel = fx[2] ? byte_lo_lat : byte_hi_lat;
    wire [1:0] xic      = ~fx[1:0];

    wire p0_bit = byte_sel[{1'b1, xic}];
    wire p1_bit = byte_sel[{1'b0, xic}];

    wire [1:0] tile_pix = {p0_bit, p1_bit};

    wire [3:0] p2_sel  = fx[2] ? p2_lo_lat : p2_hi_lat;
    wire       p2_bit  = p2_sel[xic];

    wire [7:0] tile_pen = is_exctsccr ? {1'b0, color_lat[3:0], p2_bit, tile_pix}
                                      : {1'b1, color_lat[4:0], tile_pix};

    reg  [9:0] linebuf [0:511];
    reg  [9:0] lb_q;
    reg        lb_bank = 1'b0;

    reg        lb_we;
    reg  [7:0] lb_waddr;
    reg  [9:0] lb_wdata;
    wire [7:0] lb_raddr = sx;

    always_ff @(posedge clk) begin
        if (lb_we) linebuf[{lb_bank, lb_waddr}] <= lb_wdata;
        lb_q <= linebuf[{~lb_bank, lb_raddr}];
    end

    wire [7:0] spr_line = (v_raw + 8'd1) ^ {8{crt_flip}};

    localparam [8:0] SPR_START = 9'd260;

    wire       clr_active = (h_cnt < H_VIS);
    wire [7:0] clr_addr   = h_cnt[7:0];

    reg  [3:0] spr_slot;
    reg  [5:0] spr_phase;
    reg        spr_busy;
    reg        spr_start_d;

    reg  [7:0] s_y, s_x, s_a0, s_a1;
    reg  [7:0] s_byteA, s_byteB;
    reg  [3:0] s_p2nib;
    reg  [3:0] s_row;
    reg        s_active;

    reg [255:0] lut4_opaque;

    wire [8:0] lut4_off = ioctl_addr[8:0] - 9'h120;

    always_ff @(posedge clk_dl) begin
        if (ioctl_wr && ioctl_download && (ioctl_index == 8'd7)
            && (ioctl_addr >= 25'h120) && (ioctl_addr < 25'h220))
            lut4_opaque[lut4_off[7:0]] <= |ioctl_data[3:0];
    end

    wire       s_bank = spr_slot[3];
    wire [2:0] s_num  = 3'd7 - spr_slot[2:0];
    wire       s_is4  = is_exctsccr & s_bank;
    wire       s_is3  = is_exctsccr & ~s_bank;
    wire       slot_used = is_exctsccr | ~s_bank;

    assign spr_pos_bank  = s_bank;
    assign spr_pos_addr  = {s_num, (spr_phase == 6'd1)};
    assign spr_attr_addr = {s_num, (spr_phase >= 6'd3)};

    wire [7:0] attr_src = s_is3 ? vram_rdata : spr_attr_data;

    wire [7:0] s_top_raw = 8'd255 - s_y;

    wire [7:0] s_top     = s_top_raw;
    wire [7:0] s_dy      = spr_line - s_top;
    wire       s_on_line = (s_dy < 8'd16);
    wire       s_flipx   = ~s_a0[0] ^ flip_screen;
    wire       s_flipy   = ~s_a0[1];

    wire [6:0] s_code = s_is3 ? {s_a1[4], s_a0[7:2]}
                      : s_is4 ? {1'b0,    s_a0[7:2]}
                              : {gfx_bank, s_a0[7:2]};

    wire [1:0] chunk = (spr_phase >= 6'd27) ? 2'd3 :
                       (spr_phase >= 6'd20) ? 2'd2 :
                       (spr_phase >= 6'd13) ? 2'd1 : 2'd0;
    wire [5:0] cbase = (chunk == 2'd3) ? 6'd27 :
                       (chunk == 2'd2) ? 6'd20 :
                       (chunk == 2'd1) ? 6'd13 : 6'd6;
    wire [2:0] cph   = spr_phase - cbase;
    wire       in_chunks = (spr_phase >= 6'd6) && (spr_phase <= 6'd33);

    wire [1:0] pic       = cph[1:0] - 2'd3;
    wire [3:0] s_px      = {chunk, pic};
    wire [1:0] src_chunk = s_flipx ? (2'd3 - chunk) : chunk;
    wire [1:0] s_xic     = s_flipx ? pic : (2'd3 - pic);

    wire [1:0] s_k   = src_chunk + 2'd1;
    wire [5:0] s_off = {s_row[3], s_k, s_row[2:0]};

    wire [13:0] spr_gfx_addr = is_talbot ? {2'b01, s_code[5:0], s_off}
                                         : {1'b1,  s_code,      s_off};
    wire [12:0] spr_p3_addr  = {1'b1, s_code[5:0], s_off};
    wire        spr_p3_hi    = s_code[6];
    wire [12:0] spr_g3_addr  = {(cph >= 3'd1) & (cph <= 3'd2) ? 1'b1 : 1'b0, s_code[5:0], s_off};

    wire p0_hi = s_byteA[{1'b1, s_xic}];
    wire p0_lo = s_byteA[{1'b0, s_xic}];
    wire p1_hi = s_byteB[{1'b1, s_xic}];
    wire p1_lo = s_byteB[{1'b0, s_xic}];
    wire p2_b  = s_p2nib[s_xic];

    wire [3:0] s_pix = s_is4 ? {p1_hi, p1_lo, p0_hi, p0_lo}
                     : s_is3 ? {1'b0, p2_b, p0_hi, p0_lo}
                             : {2'b00,      p0_hi, p0_lo};

    wire [7:0] s_pen = s_is4 ? {s_a1[3:0], s_pix}
                     : s_is3 ? {1'b1, s_a1[3:0], s_pix[2:0]}
                             : {palette_bank, s_a1[4:0], s_pix[1:0]};

    always_ff @(posedge clk) begin
        lb_we       <= 1'b0;
        spr_start_d <= (h_cnt == SPR_START);

        if (reset) begin
            spr_busy  <= 1'b0;
            spr_slot  <= 4'd0;
            spr_phase <= 6'd0;
            lb_bank   <= 1'b0;
        end else begin
            if (clr_active) begin
                lb_we    <= 1'b1;
                lb_waddr <= clr_addr;
                lb_wdata <= 10'd0;
            end

            if ((h_cnt == SPR_START) && !spr_start_d) begin
                spr_busy  <= 1'b1;
                spr_slot  <= 4'd0;
                spr_phase <= 6'd0;
            end else if (spr_busy) begin
                if (spr_phase == 6'd39) begin
                    spr_phase <= 6'd0;
                    spr_slot  <= spr_slot + 4'd1;
                    if (spr_slot == 4'd15) spr_busy <= 1'b0;
                end else begin
                    spr_phase <= spr_phase + 6'd1;
                end

                if (slot_used) begin
                    case (spr_phase)
                        6'd0: s_y  <= spr_pos_data;
                        6'd1: s_x  <= spr_pos_data;
                        6'd3: s_a0 <= attr_src;
                        6'd4: s_a1 <= attr_src;
                        6'd5: begin
                            s_active <= s_on_line;
                            s_row    <= s_flipy ? (4'd15 - s_dy[3:0]) : s_dy[3:0];
                        end
                        default: ;
                    endcase

                    if (in_chunks) begin
                        if (cph == 3'd1) begin
                            s_byteA <= s_is4 ? gfx3_data : gfx_data;
                            s_p2nib <= spr_p3_hi ? gfx_p3_data[7:4] : gfx_p3_data[3:0];
                        end
                        if (cph == 3'd2) s_byteB <= gfx3_data;

                        if (cph >= 3'd3 && s_active && slot_used
                            && (s_is4 ? lut4_opaque[s_pen] : (s_pix != 4'd0))) begin
                            lb_we    <= 1'b1;
                            lb_waddr <= (flip_screen ? (8'd240 - (s_x - 8'd16))
                                                     : (s_x - 8'd16)) + {4'd0, s_px};
                            lb_wdata <= {1'b1, s_is4, s_pen};
                        end
                    end
                end
            end

            if (cen_pix && (h_cnt == H_TOTAL - 9'd1)) lb_bank <= ~lb_bank;
        end
    end

    assign gfx3_addr = spr_g3_addr;

    assign vram_addr_mux = (spr_busy && s_is3) ? {7'd0, spr_attr_addr} : vram_raddr;

    wire       spr_opaque = lb_q[9];
    wire       spr_is4    = lb_q[8];
    wire [7:0] spr_pen    = lb_q[7:0];

    wire [7:0] active_pen = spr_opaque ? spr_pen : tile_pen;

    wire [7:0] pen_swapped = {active_pen[2], active_pen[7], active_pen[6], active_pen[5],
                              active_pen[4], active_pen[3], active_pen[1], active_pen[0]};

    wire [7:0] lut_index = is_exctsccr ? pen_swapped : active_pen;

    wire pen_is4 = spr_opaque & spr_is4;

    assign prom_addr = pen_is4 ? (10'h120 + {2'd0, active_pen})
                               : (10'h020 + {2'd0, lut_index});

    wire [4:0] color_index = pen_is4     ? {1'b1,          prom_data[3:0]}
                           : is_exctsccr ? {active_pen[7], prom_data[3:0]}
                                         : {palette_bank,  prom_data[3:0]};

    reg [7:0] pal_prom [0:31];

    always_ff @(posedge clk_dl) begin
        if (ioctl_wr && ioctl_download && (ioctl_index == 8'd7) && (ioctl_addr < 25'h20))
            pal_prom[ioctl_addr[4:0]] <= ioctl_data;
    end

    wire [7:0] pal_byte = pal_prom[color_index];

    function automatic [7:0] rgb3;
        input b0, b1, b2;
        begin
            rgb3 = (b0 ? 8'h21 : 8'h00) + (b1 ? 8'h47 : 8'h00) + (b2 ? 8'h97 : 8'h00);
        end
    endfunction

    function automatic [7:0] rgb2;
        input b0, b1;
        begin
            rgb2 = (b0 ? 8'h51 : 8'h00) + (b1 ? 8'hAE : 8'h00);
        end
    endfunction

    wire [7:0] r_lvl = rgb3(pal_byte[0], pal_byte[1], pal_byte[2]);
    wire [7:0] g_lvl = rgb3(pal_byte[3], pal_byte[4], pal_byte[5]);
    wire [7:0] b_lvl = is_exctsccr ? rgb3(1'b0, pal_byte[6], pal_byte[7])
                                   : rgb2(pal_byte[6], pal_byte[7]);

    wire blanking = hblk || vblk;

    assign VGA_R = blanking ? 8'd0 : r_lvl;
    assign VGA_G = blanking ? 8'd0 : g_lvl;
    assign VGA_B = blanking ? 8'd0 : b_lvl;

endmodule
