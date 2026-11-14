//============================================================================
//
// ChampionBaseball for MiSTer
// Copyright (C) 2026 Rodimus
// Based on Tutankham core structure
//
//  Permission is hereby granted, free of charge, to any person obtaining a
//  copy of this software and associated documentation files (the "Software"),
//  to deal in the Software without restriction, including without limitation
//  the rights to use, copy, modify, merge, publish, distribute, sublicense,
//  and/or sell copies of the Software, and to permit persons to whom the
//  Software is furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in
//  all copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
//  FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
//  DEALINGS IN THE SOFTWARE.
//
//============================================================================

module emu
(
    `include "sys/emu_ports.vh"
);

assign ADC_BUS  = 'Z;
assign USER_OUT = '1;
assign {UART_RTS, UART_TXD, UART_DTR} = 0;
assign {SD_SCK, SD_MOSI, SD_CS} = 'Z;
assign {SDRAM_DQ, SDRAM_A, SDRAM_BA, SDRAM_CLK, SDRAM_CKE, SDRAM_DQML, SDRAM_DQMH, SDRAM_nWE, SDRAM_nCAS, SDRAM_nRAS, SDRAM_nCS} = 'Z;

assign VGA_F1 = 0;
assign VGA_SCALER = 0;
assign VGA_DISABLE = 0;
assign FB_FORCE_BLANK = 0;
assign HDMI_FREEZE = 0;
assign HDMI_BLACKOUT = 0;
assign HDMI_BOB_DEINT = 0;

wire signed [15:0] audio_l, audio_r;
assign AUDIO_L = pause_cpu ? 16'd0 : audio_l;
assign AUDIO_R = pause_cpu ? 16'd0 : audio_r;
assign AUDIO_S = 1;
assign AUDIO_MIX = 0;

assign LED_DISK  = 0;
assign LED_POWER = 0;
assign LED_USER  = ioctl_download;
assign BUTTONS = 0;

wire [1:0] ar = status[14:13];

wire [7:0] set_id;
wire is_vertical = (set_id >= 8'h07);

wire horz = ~is_vertical | status[12];

wire        art_fb;
wire        art_wait, art_avail;
wire [11:0] art_cw, art_ch;
assign VIDEO_ARX = (!ar && art_fb) ? art_cw : horz ? ((!ar) ? 12'd4 : (ar - 1'd1)) : ((!ar) ? 12'd3 : (ar - 1'd1));
assign VIDEO_ARY = (!ar && art_fb) ? art_ch : horz ? ((!ar) ? 12'd3 : 12'd0) : ((!ar) ? 12'd4 : 12'd0);

`include "build_id.v"
localparam CONF_STR = {
	"CHAMPIONBASEBALL;;",
	"P1,Video Options;",
	"P1ODE,Aspect Ratio,Original,Full screen,[ARC1],[ARC2];",
	"P1OC,Orientation,Vert,Horz;",
	"P1OB,HDMI Flip,Off,On;",
	"P1OM,CRT Flip,Off,On;",
	"P1OFH,Scandoubler Fx,None,HQ2x,CRT 25%,CRT 50%,CRT 75%;",
	"-;",
	"P2,Pause Options;",
	"P2OP,Pause when OSD is open,On,Off;",
	"P2OQ,Dim video after 10s,On,Off;",
	"-;",
	"P3,High Score Options;",
	"P3OR,Autosave Hiscores,Off,On;",
	"-;",
	"H1P4,Game Options;",
	"H1P4-,Artwork (MAME layout views);",
	"H1P4O[50:48],View,Off,View 1,View 2,View 3,View 4,View 5,View 6,View 7;",
	"H1P4O[51],Backdrop,On,Off;",
	"H1P4O[52],Overlay,On,Off;",
	"H1P4O[53],Bezel,On,Off;",
	"H1P4O[56],Control Panel,On,Off;",
	"H1P4O[54],Side Art,On,Off;",
	"H1P4O[55],Zoom to Screen,Off,On;",
	"H1-;",
	"DIP;",
	"-;",
	"R0,Reset;",
	"J1,Throw,Steal,Changes,Coin,Start 1P,Start 2P,Pause;",
	"jn,A,B,X,Select,Start,R,L;",
	"V,v",`BUILD_DATE
};

wire        forced_scandoubler;
wire  [1:0] buttons;
wire [127:0] status;
wire [10:0] ps2_key;

wire        ioctl_download;
wire        ioctl_upload;
wire        ioctl_upload_req;
wire  [7:0] ioctl_index;
wire        ioctl_wr;
wire [26:0] ioctl_addr27;
wire [24:0] ioctl_addr = ioctl_addr27[24:0];
wire  [7:0] ioctl_dout;
wire  [7:0] ioctl_din;

wire [15:0] joystick_0, joystick_1;
wire [15:0] joy = joystick_0 | joystick_1;

wire [21:0] gamma_bus;
wire        direct_video;
wire        video_rotated;

hps_io #(.CONF_STR(CONF_STR)) hps_io
(
	.clk_sys(CLK_49M),
	.HPS_BUS(HPS_BUS),
	.EXT_BUS(),
	.gamma_bus(gamma_bus),
	.direct_video(direct_video),
	.video_rotated(video_rotated),

	.forced_scandoubler(forced_scandoubler),

	.buttons(buttons),
	.status(status),
	.status_menumask({~art_avail, direct_video}),

	.ioctl_download(ioctl_download),
	.ioctl_upload(ioctl_upload),
	.ioctl_upload_req(ioctl_upload_req),
	.ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr27),
	.ioctl_dout(ioctl_dout),
	.ioctl_din(ioctl_din),
	.ioctl_wait(art_wait),
	.ioctl_index(ioctl_index),

	.joystick_0(joystick_0),
	.joystick_1(joystick_1),
	.ps2_key(ps2_key)
);

wire CLK_49M;
wire locked;

pll pll
(
    .refclk(CLK_50M),
    .rst(0),
    .outclk_0(CLK_49M),
    .locked(locked)
);

assign CLK_VIDEO = CLK_49M;

wire reset = RESET | status[0] | buttons[1] | ioctl_download;

/* verilator lint_off UNUSED */
wire [12:0] kb;
/* verilator lint_on UNUSED */
wire  [0:0] kbx;
wire btn_up       = kb[0];
wire btn_down     = kb[1];
wire btn_left     = kb[2];
wire btn_right    = kb[3];
wire btn_fire     = kb[4];
wire btn_fire2    = kbx[0];
wire btn_coin1    = kb[8];
wire btn_coin2    = kb[9];
wire btn_1p_start = kb[6];
wire btn_2p_start = kb[7];
wire btn_pause    = kb[12];
wire btn_service  = kb[10];

wire m_up1      = btn_up        | joystick_0[3];
wire m_down1    = btn_down      | joystick_0[2];
wire m_left1    = btn_left      | joystick_0[1];
wire m_right1   = btn_right     | joystick_0[0];
wire m_throw1   = btn_fire      | joystick_0[4];
wire m_steal1   = btn_fire2     | joystick_0[5];
wire m_change1  =                 joystick_0[6];

wire m_up2      = btn_up        | joystick_1[3];
wire m_down2    = btn_down      | joystick_1[2];
wire m_left2    = btn_left      | joystick_1[1];
wire m_right2   = btn_right     | joystick_1[0];
wire m_throw2   = btn_fire      | joystick_1[4];
wire m_steal2   = btn_fire2     | joystick_1[5];
wire m_change2  =                 joystick_1[6];

wire m_coin1    = btn_coin1     | joystick_0[7];
wire m_coin2    = btn_coin2     | joystick_1[7];
wire m_start1   = btn_1p_start  | joystick_0[8];
wire m_start2   = btn_2p_start  | joystick_0[9];
wire m_pause    = btn_pause     | joystick_0[10];

wire m_service  = btn_service                  ;

wire ctrl_flip_ud = 1'b0;

wire m_up1_c   = ctrl_flip_ud ? m_down1 : m_up1;
wire m_down1_c = ctrl_flip_ud ? m_up1   : m_down1;
wire m_up2_c   = ctrl_flip_ud ? m_down2 : m_up2;
wire m_down2_c = ctrl_flip_ud ? m_up2   : m_down2;

wire m_left1_c  = ctrl_flip_ud ? m_right1 : m_left1;
wire m_right1_c = ctrl_flip_ud ? m_left1  : m_right1;
wire m_left2_c  = ctrl_flip_ud ? m_right2 : m_left2;
wire m_right2_c = ctrl_flip_ud ? m_left2  : m_right2;

wire [7:0] p1_port     = ~{m_down1_c, m_right1_c, m_left1_c, m_up1_c, m_steal1, m_change1, 1'b0, m_throw1};
wire [7:0] p2_port     = ~{m_down2_c, m_right2_c, m_left2_c, m_up2_c, m_steal2, m_change2, 1'b0, m_throw2};
wire [7:0] system_port = ~{4'b0000, m_coin2, m_coin1, m_start2, m_start1};

wire [15:0] hs_address      = 16'd0;
wire  [7:0] hs_data_in      = 8'd0;
wire  [7:0] hs_data_out;
wire        hs_write_enable = 1'b0;
wire        hs_access_read  = 1'b0;
wire        hs_access_write = 1'b0;
wire        hs_pause        = 1'b0;
wire        hs_configured   = 1'b0;
assign      ioctl_din       = 8'd0;
assign      ioctl_upload_req = 1'b0;

wire pause_cpu;
ctl_keyboard #(.NX(1), .NXO(1), .XKEYS(24'h10_12_00)) u_kb(.clk(CLK_49M), .ps2_key(ps2_key), .pause(pause_cpu), .kb(kb),
	.kbx(kbx));
wire [23:0] rgb_out;
pause #(8,8,8,10) pause
(
	.*,
	.clk_sys(CLK_49M),
	.user_button(m_pause),
	.pause_request(hs_pause),
	.options(~status[26:25])
);

wire hblank, vblank;
wire hs, vs;
wire [7:0] r, g, b;
wire ce_pix;
wire bd_hblank, bd_vblank, bd_hs, bd_vs;
wire [7:0] bd_r, bd_g, bd_b;

wire        art_run, art_ddr;
wire [31:0] art_fb_base;
wire  [7:0] art_burstcnt, art_be;
wire [28:0] art_addr;
wire [63:0] art_din;
wire        art_rd, art_we, art_clk;
artwork #(.IDX(8'd10)) artwork
(
	.clk(CLK_49M),
	.sel({1'b0, status[50:48]}), .layer_off({status[56], status[53:51]}), .side_off(status[54]), .zoom(status[55]),
	.crt_flip(status[22]), .hdmi_flip(status[11]), .turn(is_vertical & status[12]), .avail(art_avail),
	.hdmi_w(HDMI_WIDTH), .hdmi_h(HDMI_HEIGHT),
	.ioctl_download(ioctl_download), .ioctl_index(ioctl_index), .ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr27), .ioctl_dout(ioctl_dout), .ioctl_wait(art_wait),
	.ce_pix(ce_pix),
	.hs_in(bd_hs), .vs_in(bd_vs), .hblank_in(bd_hblank), .vblank_in(bd_vblank), .rgb_in({bd_r, bd_g, bd_b}),
	.hs_out(hs), .vs_out(vs), .hblank_out(hblank), .vblank_out(vblank), .rgb_out({r, g, b}),
	.running(art_run), .ddr_owner(art_ddr), .canvas_w(art_cw), .canvas_h(art_ch),
	.fb_base(art_fb_base), .fb_vbl(FB_VBL),
	.DDRAM_CLK(art_clk), .DDRAM_BUSY(DDRAM_BUSY), .DDRAM_BURSTCNT(art_burstcnt), .DDRAM_ADDR(art_addr),
	.DDRAM_DOUT(DDRAM_DOUT), .DDRAM_DOUT_READY(DDRAM_DOUT_READY), .DDRAM_RD(art_rd),
	.DDRAM_DIN(art_din), .DDRAM_BE(art_be), .DDRAM_WE(art_we)
);
assign art_fb = art_run & ~direct_video;

wire rotate_ccw  = 1'b1;
wire no_rotate   = ~is_vertical | status[12] | direct_video;
wire flip        = status[11];
wire        sr_fb_en, sr_clk, sr_rd, sr_we;
wire  [4:0] sr_fb_format;
wire [11:0] sr_fb_w, sr_fb_h;
wire [31:0] sr_fb_base;
wire [13:0] sr_fb_stride;
wire  [7:0] sr_burstcnt, sr_be;
wire [28:0] sr_addr;
wire [63:0] sr_din;
screen_rotate screen_rotate
(
	.*,
	.FB_EN(sr_fb_en), .FB_FORMAT(sr_fb_format), .FB_WIDTH(sr_fb_w), .FB_HEIGHT(sr_fb_h),
	.FB_BASE(sr_fb_base), .FB_STRIDE(sr_fb_stride),
	.DDRAM_CLK(sr_clk), .DDRAM_BURSTCNT(sr_burstcnt), .DDRAM_ADDR(sr_addr), .DDRAM_DIN(sr_din),
	.DDRAM_BE(sr_be), .DDRAM_WE(sr_we), .DDRAM_RD(sr_rd)
);

assign FB_EN     = art_fb | sr_fb_en;
assign FB_FORMAT = art_fb ? 5'b00110  : sr_fb_format;
assign FB_WIDTH  = art_fb ? art_cw    : sr_fb_w;
assign FB_HEIGHT = art_fb ? art_ch    : sr_fb_h;
assign FB_BASE   = art_fb ? art_fb_base : sr_fb_base;
assign FB_STRIDE = art_fb ? 14'd8192  : sr_fb_stride;
assign DDRAM_CLK      = CLK_49M;
assign DDRAM_BURSTCNT = art_ddr ? art_burstcnt : sr_burstcnt;
assign DDRAM_ADDR     = art_ddr ? art_addr : sr_addr;
assign DDRAM_DIN      = art_ddr ? art_din : sr_din;
assign DDRAM_BE       = art_ddr ? art_be : sr_be;
assign DDRAM_WE       = art_ddr ? art_we : sr_we;
assign DDRAM_RD       = art_ddr ? art_rd : sr_rd;

arcade_video #(256,24) arcade_video
(
	.*,

	.clk_video(CLK_49M),

	.RGB_in(rgb_out),
	.HBlank(hblank),
	.VBlank(vblank),
	.HSync(hs),
	.VSync(vs),

	.fx(status[17:15])
);

reg [7:0] dip_sw[8] = '{8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00};
always @(posedge CLK_49M) begin
	if (ioctl_wr && (ioctl_index == 8'd254) && !ioctl_addr[24:3])
		dip_sw[ioctl_addr[2:0]] <= ioctl_dout;
end
wire [7:0] sw0 = dip_sw[0];

championbaseball_dispatcher championbaseball_inst
(
	.reset(reset),

	.clk_49m(CLK_49M),

	.p1(p1_port),
	.p2(p2_port),
	.dsw(sw0),
	.system(system_port),

	.set_id(set_id),

	.video_hsync(bd_hs),
	.video_vsync(bd_vs),
	.video_vblank(bd_vblank),
	.video_hblank(bd_hblank),
	.ce_pix(ce_pix),

	.video_r(bd_r),
	.video_g(bd_g),
	.video_b(bd_b),

	.sound_l(audio_l),
	.sound_r(audio_r),

	.ioctl_addr(ioctl_addr),
	.ioctl_data(ioctl_dout),
	.ioctl_wr(ioctl_wr),
	.ioctl_index(ioctl_index),
	.ioctl_download(ioctl_download),

	.hs_addr(hs_address),
	.hs_din(hs_data_in),
	.hs_dout(hs_data_out),
	.hs_we(hs_write_enable),
	.hs_active(hs_access_read | hs_access_write),

	.crt_flip(status[22]),

	.pause(pause_cpu)
);

endmodule
