// HDMI 640x480 test pattern for Tang Nano 9K (GW1NR-9C)
// Adapted from fpga4fun.com HDMI_test — Xilinx DCM/OBUFDS replaced with Gowin primitives.
//
// Big picture:
//   27 MHz crystal → rPLL (~126 MHz) → CLKDIV/5 (~25.2 MHz pixel clock)
//   Pixel logic makes RGB + sync → TMDS 8b/10b encode → OSER10 serializes → ELVDS to HDMI connector

module HDMI (
    input  wire       sys_clk,      // 27 MHz onboard crystal (NOT 25 MHz)
    input  wire       sys_rst_n,    // active-low button S1
    output wire [2:0] tmds_d_p,     // HDMI data +  (2=red, 1=green, 0=blue)
    output wire [2:0] tmds_d_n,     // HDMI data -
    output wire       tmds_clk_p,   // HDMI clock +
    output wire       tmds_clk_n    // HDMI clock -
);

    // =========================================================================
    // 1) CLOCK SHIFT — why this exists
    // -------------------------------------------------------------------------
    // HDMI 640x480@60 wants ~25.175 MHz pixel clock. The board only has 27 MHz.
    // TMDS also needs a bit clock 10× the pixel rate. Gowin's OSER10 does that
    // with a 5× clock (DDR serialization), so we generate:
    //   clk_5x    ≈ 126 MHz   = 5 × 25.2 MHz   (feeds OSER10.FCLK)
    //   pixclk    ≈ 25.2 MHz  = clk_5x / 5     (feeds all pixel logic)
    //
    // Critical: pixclk MUST be divided from clk_5x (same PLL tree), not from a
    // second independent PLL — OSER10 needs them phase-aligned.
    // =========================================================================
    wire clk_5x;
    wire pixclk;
    wire pll_lock;

    Gowin_rPLL u_pll (
        .clkin  (sys_clk),   // 27 MHz in
        .clkout (clk_5x),    // ~126 MHz out
        .lock   (pll_lock)   // high when PLL is stable — use as part of reset
    );

    Gowin_CLKDIV u_div5 (
        .hclkin (clk_5x),
        .resetn (pll_lock),  // don't divide until PLL has locked
        .clkout (pixclk)     // ~25.2 MHz pixel clock
    );

    // Hold everything in reset until clocks are good AND button is released
    wire rst = ~(sys_rst_n & pll_lock);  // active-high reset for OSER10

    // =========================================================================
    // 2) VIDEO TIMING (640×480 @ 60 Hz, VGA-style totals 800×525)
    // -------------------------------------------------------------------------
    // Walks a raster: CounterX = pixel column, CounterY = line.
    // DrawArea marks the visible 640×480 window; outside that we send blanking
    // + sync codes instead of pixels (HDMI requirement).
    // =========================================================================
    reg [9:0] CounterX = 0, CounterY = 0;
    reg hSync, vSync, DrawArea;

    always @(posedge pixclk) DrawArea <= (CounterX < 640) && (CounterY < 480);

    always @(posedge pixclk)
        CounterX <= (CounterX == 799) ? 10'd0 : CounterX + 10'd1;

    always @(posedge pixclk)
        if (CounterX == 799)
            CounterY <= (CounterY == 524) ? 10'd0 : CounterY + 10'd1;

    // Sync pulses during blanking (not during DrawArea)
    always @(posedge pixclk) hSync <= (CounterX >= 656) && (CounterX < 752);
    always @(posedge pixclk) vSync <= (CounterY >= 490) && (CounterY < 492);

    // Frame counter: advances once per frame (at last pixel of last blanking line)
    // so animation state changes between frames, not mid-scan (no tearing).
    reg [7:0] frame = 0;
    always @(posedge pixclk)
        if (CounterX == 799 && CounterY == 524)
            frame <= frame + 8'd1;

    // =========================================================================
    // Game of Life — 32×24 cells, each shown as a 20×20 HDMI pixel block
    // -------------------------------------------------------------------------
    // HDMI stays 640×480. Life is 32×24 bits/buffer so it fits in DFFs.
    // Cell coords are tracked with counters (not /20 or %20 — those synthesize
    // poorly on Gowin). Seeds are applied on rst: `initial` alone often does
    // not load into the bitstream, which leaves an all-dead (black) board.
    // =========================================================================
    localparam LIFE_W  = 32;
    localparam LIFE_H  = 24;
    localparam CELL_PX = 20;  // 32*20=640, 24*20=480
    localparam div = 60;

    reg [7:0] neighbor_pixel_value;
    reg Frame_buffer_a [0:LIFE_W-1][0:LIFE_H-1];
    reg Frame_buffer_b [0:LIFE_W-1][0:LIFE_H-1];
    reg swap_buffer;
    
    // Pixel position inside the current 20×20 cell, and cell indices
    reg [4:0] sub_x, sub_y;     // 0..19
    reg [4:0] cell_x, cell_y;   // 0..31 / 0..23
    wire cell_origin = (CounterX < 640) && (CounterY < 480) &&
                       (sub_x == 5'd0) && (sub_y == 5'd0);

    integer ix, iy;

    // Walk cell_x/y in lockstep with the HDMI raster (no division)
    always @(posedge pixclk) begin
        if (rst) begin
            sub_x  <= 5'd0;
            sub_y  <= 5'd0;
            cell_x <= 5'd0;
            cell_y <= 5'd0;
        end else if (CounterX == 10'd799) begin
            // End of HDMI line: X resets; Y advances once per visible line
            sub_x  <= 5'd0;
            cell_x <= 5'd0;
            if (CounterY == 10'd524) begin
                sub_y  <= 5'd0;
                cell_y <= 5'd0;
            end else if (CounterY < 10'd479) begin
                if (sub_y == 5'd19) begin
                    sub_y  <= 5'd0;
                    cell_y <= cell_y + 5'd1;
                end else begin
                    sub_y <= sub_y + 5'd1;
                end
            end
        end else if (CounterX < 10'd639) begin
            if (sub_x == 5'd19) begin
                sub_x  <= 5'd0;
                cell_x <= cell_x + 5'd1;
            end else begin
                sub_x <= sub_x + 5'd1;
            end
        end
    end

    reg [5:0] counter_div = 6'd0;

    always @(posedge pixclk) begin
        if (rst) begin
            swap_buffer <= 1'b0;
            for (iy = 0; iy < LIFE_H; iy = iy + 1)
                for (ix = 0; ix < LIFE_W; ix = ix + 1) begin
                    Frame_buffer_a[ix][iy] <= 1'b0;
                    Frame_buffer_b[ix][iy] <= 1'b0;
                end
            // Seeds (cell coords) — applied after the clear in the same reset
            Frame_buffer_a[5][3]   <= 1'b1;
            Frame_buffer_a[6][4]   <= 1'b1;
            Frame_buffer_a[4][5]   <= 1'b1;
            Frame_buffer_a[5][5]   <= 1'b1;
            Frame_buffer_a[6][5]   <= 1'b1;
            Frame_buffer_a[14][8]  <= 1'b1;
            Frame_buffer_a[15][8]  <= 1'b1;
            Frame_buffer_a[16][8]  <= 1'b1;
            Frame_buffer_a[22][12] <= 1'b1;
            Frame_buffer_a[23][12] <= 1'b1;
            Frame_buffer_a[24][12] <= 1'b1;
            Frame_buffer_a[21][13] <= 1'b1;
            Frame_buffer_a[22][13] <= 1'b1;
            Frame_buffer_a[23][13] <= 1'b1;
        end else begin
            // Interior cells only (edges stay 0 — no wrap)
            if (cell_origin && cell_x > 0 && cell_x < LIFE_W-1 &&
                cell_y > 0 && cell_y < LIFE_H-1) begin
                if (swap_buffer == 1'b0) begin
                    neighbor_pixel_value =
                        Frame_buffer_a[cell_x-1][cell_y-1] +
                        Frame_buffer_a[cell_x  ][cell_y-1] +
                        Frame_buffer_a[cell_x+1][cell_y-1] +
                        Frame_buffer_a[cell_x-1][cell_y  ] +
                        Frame_buffer_a[cell_x+1][cell_y  ] +
                        Frame_buffer_a[cell_x-1][cell_y+1] +
                        Frame_buffer_a[cell_x  ][cell_y+1] +
                        Frame_buffer_a[cell_x+1][cell_y+1];
                    if (neighbor_pixel_value == 8'd3)
                        Frame_buffer_b[cell_x][cell_y] <= 1'b1;
                    else if (neighbor_pixel_value == 8'd2)
                        Frame_buffer_b[cell_x][cell_y] <= Frame_buffer_a[cell_x][cell_y];
                    else
                        Frame_buffer_b[cell_x][cell_y] <= 1'b0;
                end else begin
                    neighbor_pixel_value =
                        Frame_buffer_b[cell_x-1][cell_y-1] +
                        Frame_buffer_b[cell_x  ][cell_y-1] +
                        Frame_buffer_b[cell_x+1][cell_y-1] +
                        Frame_buffer_b[cell_x-1][cell_y  ] +
                        Frame_buffer_b[cell_x+1][cell_y  ] +
                        Frame_buffer_b[cell_x-1][cell_y+1] +
                        Frame_buffer_b[cell_x  ][cell_y+1] +
                        Frame_buffer_b[cell_x+1][cell_y+1];
                    if (neighbor_pixel_value == 8'd3)
                        Frame_buffer_a[cell_x][cell_y] <= 1'b1;
                    else if (neighbor_pixel_value == 8'd2)
                        Frame_buffer_a[cell_x][cell_y] <= Frame_buffer_b[cell_x][cell_y];
                    else
                        Frame_buffer_a[cell_x][cell_y] <= 1'b0;
                end
            end

            // One generation per HDMI frame
            if (CounterX == 799 && CounterY == 524)
                if (counter_div == div - 1) begin
                    swap_buffer <= ~swap_buffer;
                    counter_div <= 6'd0;
                end
                else begin
                    counter_div <= counter_div + 6'd1;
                end
        end
    end

    // =========================================================================
    // 3) DISPLAY — alive = white, dead = dark gray (proves HDMI is alive)
    // =========================================================================
    reg [7:0] red, green, blue;
    wire cell_alive = (swap_buffer == 1'b0)
                    ? Frame_buffer_a[cell_x][cell_y]
                    : Frame_buffer_b[cell_x][cell_y];

    always @(posedge pixclk) begin
        if (cell_alive) begin
            red   <= 8'hFF;
            green <= 8'hFF;
            blue  <= 8'hFF;
        end else begin
            // Dim gray so a "black screen" vs "no signal" is obvious
            red   <= 8'h20;
            green <= 8'h20;
            blue  <= 8'h28;
        end
    end
    // =========================================================================
    // 4) TMDS ENCODE — 8-bit color → 10-bit DC-balanced symbols
    // -------------------------------------------------------------------------
    // HDMI doesn't send raw RGB. Each channel is 8b/10b TMDS-encoded.
    // During blanking (VDE=0), blue channel carries {vSync,hSync} as control;
    // red/green control bits are 00 here.
    // =========================================================================
    wire [9:0] TMDS_red, TMDS_green, TMDS_blue;

    TMDS_encoder encode_R (
        .clk (pixclk), .VD (red),   .CD (2'b00),           .VDE (DrawArea), .TMDS (TMDS_red)
    );
    TMDS_encoder encode_G (
        .clk (pixclk), .VD (green), .CD (2'b00),           .VDE (DrawArea), .TMDS (TMDS_green)
    );
    TMDS_encoder encode_B (
        .clk (pixclk), .VD (blue),  .CD ({vSync, hSync}),  .VDE (DrawArea), .TMDS (TMDS_blue)
    );

    // =========================================================================
    // 5) SERIALIZE + DIFFERENTIAL OUT — replaces Xilinx soft-shifter + OBUFDS
    // -------------------------------------------------------------------------
    // fpga4fun ran a fabric shift-register at 10× pixel clock (~250 MHz).
    // That is harsh on this small FPGA and uses Xilinx DCM/OBUFDS.
    //
    // On Tang Nano 9K we use hardware instead:
    //   OSER10      — 10:1 serializer, clocked by pixclk + clk_5x
    //   ELVDS_OBUF  — emulated LVDS differential driver (required on GW1NR-9;
    //                 TLVDS_OBUF is NOT available on this part)
    //
    // Clock lane: serialize 5 ones + 5 zeros → square wave at pixel rate,
    // which is what the monitor uses as the TMDS character clock.
    // =========================================================================
    wire [9:0] TMDS_clk_bits = 10'b0000011111;

    wire ser_r, ser_g, ser_b, ser_c;

    OSER10 #(.GSREN("false"), .LSREN("true")) oser_r (
        .D0(TMDS_red[0]), .D1(TMDS_red[1]), .D2(TMDS_red[2]), .D3(TMDS_red[3]), .D4(TMDS_red[4]),
        .D5(TMDS_red[5]), .D6(TMDS_red[6]), .D7(TMDS_red[7]), .D8(TMDS_red[8]), .D9(TMDS_red[9]),
        .PCLK(pixclk), .FCLK(clk_5x), .RESET(rst), .Q(ser_r)
    );
    OSER10 #(.GSREN("false"), .LSREN("true")) oser_g (
        .D0(TMDS_green[0]), .D1(TMDS_green[1]), .D2(TMDS_green[2]), .D3(TMDS_green[3]), .D4(TMDS_green[4]),
        .D5(TMDS_green[5]), .D6(TMDS_green[6]), .D7(TMDS_green[7]), .D8(TMDS_green[8]), .D9(TMDS_green[9]),
        .PCLK(pixclk), .FCLK(clk_5x), .RESET(rst), .Q(ser_g)
    );
    OSER10 #(.GSREN("false"), .LSREN("true")) oser_b (
        .D0(TMDS_blue[0]), .D1(TMDS_blue[1]), .D2(TMDS_blue[2]), .D3(TMDS_blue[3]), .D4(TMDS_blue[4]),
        .D5(TMDS_blue[5]), .D6(TMDS_blue[6]), .D7(TMDS_blue[7]), .D8(TMDS_blue[8]), .D9(TMDS_blue[9]),
        .PCLK(pixclk), .FCLK(clk_5x), .RESET(rst), .Q(ser_b)
    );
    OSER10 #(.GSREN("false"), .LSREN("true")) oser_c (
        .D0(TMDS_clk_bits[0]), .D1(TMDS_clk_bits[1]), .D2(TMDS_clk_bits[2]), .D3(TMDS_clk_bits[3]), .D4(TMDS_clk_bits[4]),
        .D5(TMDS_clk_bits[5]), .D6(TMDS_clk_bits[6]), .D7(TMDS_clk_bits[7]), .D8(TMDS_clk_bits[8]), .D9(TMDS_clk_bits[9]),
        .PCLK(pixclk), .FCLK(clk_5x), .RESET(rst), .Q(ser_c)
    );

    // Channel map: [2]=red, [1]=green, [0]=blue (same as original fpga4fun TMDSp indexing)
    ELVDS_OBUF obuf_r (.I(ser_r), .O(tmds_d_p[2]), .OB(tmds_d_n[2]));
    ELVDS_OBUF obuf_g (.I(ser_g), .O(tmds_d_p[1]), .OB(tmds_d_n[1]));
    ELVDS_OBUF obuf_b (.I(ser_b), .O(tmds_d_p[0]), .OB(tmds_d_n[0]));
    ELVDS_OBUF obuf_c (.I(ser_c), .O(tmds_clk_p),  .OB(tmds_clk_n));

endmodule


// =============================================================================
// TMDS_encoder — unchanged algorithm from fpga4fun
// Turns 8-bit video (or 2-bit control during blanking) into a 10-bit TMDS word.
// =============================================================================
module TMDS_encoder (
    input            clk,
    input      [7:0] VD,   // video data
    input      [1:0] CD,   // control data (used when VDE=0)
    input            VDE,  // 1 = send video, 0 = send control
    output reg [9:0] TMDS = 0
);

    wire [3:0] Nb1s = VD[0] + VD[1] + VD[2] + VD[3] + VD[4] + VD[5] + VD[6] + VD[7];
    wire XNOR = (Nb1s > 4'd4) || (Nb1s == 4'd4 && VD[0] == 1'b0);
    wire [8:0] q_m = {~XNOR, q_m[6:0] ^ VD[7:1] ^ {7{XNOR}}, VD[0]};

    reg  [3:0] balance_acc = 0;
    wire [3:0] balance = q_m[0] + q_m[1] + q_m[2] + q_m[3] + q_m[4] + q_m[5] + q_m[6] + q_m[7] - 4'd4;
    wire balance_sign_eq = (balance[3] == balance_acc[3]);
    wire invert_q_m = (balance == 0 || balance_acc == 0) ? ~q_m[8] : balance_sign_eq;
    wire [3:0] balance_acc_inc = balance - ({q_m[8] ^ ~balance_sign_eq} & ~(balance == 0 || balance_acc == 0));
    wire [3:0] balance_acc_new = invert_q_m ? balance_acc - balance_acc_inc : balance_acc + balance_acc_inc;
    wire [9:0] TMDS_data = {invert_q_m, q_m[8], q_m[7:0] ^ {8{invert_q_m}}};
    wire [9:0] TMDS_code = CD[1] ? (CD[0] ? 10'b1010101011 : 10'b0101010100)
                                 : (CD[0] ? 10'b0010101011 : 10'b1101010100);

    always @(posedge clk) TMDS <= VDE ? TMDS_data : TMDS_code;
    always @(posedge clk) balance_acc <= VDE ? balance_acc_new : 4'h0;
endmodule


// =============================================================================
// Gowin rPLL: 27 MHz → ~125.875 MHz
// Fout ≈ Fin × (FBDIV_SEL+1) / (IDIV_SEL+1) = 27 × 14 / 3 = 126 MHz
// Why a PLL (not a counter): only a PLL makes a clean high-speed clock suitable
// for OSER10, with a LOCK signal so we don't blast garbage into the HDMI PHY.
// =============================================================================
module Gowin_rPLL (
    output clkout,
    output lock,
    input  clkin
);
    wire clkoutp_o, clkoutd_o, clkoutd3_o, gw_gnd;
    assign gw_gnd = 1'b0;

    rPLL rpll_inst (
        .CLKOUT(clkout), .LOCK(lock),
        .CLKOUTP(clkoutp_o), .CLKOUTD(clkoutd_o), .CLKOUTD3(clkoutd3_o),
        .RESET(gw_gnd), .RESET_P(gw_gnd), .CLKIN(clkin), .CLKFB(gw_gnd),
        .FBDSEL({6{gw_gnd}}), .IDSEL({6{gw_gnd}}), .ODSEL({6{gw_gnd}}),
        .PSDA({4{gw_gnd}}), .DUTYDA({4{gw_gnd}}), .FDLY({4{gw_gnd}})
    );

    defparam rpll_inst.FCLKIN = "27";
    defparam rpll_inst.DYN_IDIV_SEL = "false";
    defparam rpll_inst.IDIV_SEL = 2;
    defparam rpll_inst.DYN_FBDIV_SEL = "false";
    defparam rpll_inst.FBDIV_SEL = 13;
    defparam rpll_inst.DYN_ODIV_SEL = "false";
    defparam rpll_inst.ODIV_SEL = 4;
    defparam rpll_inst.PSDA_SEL = "0000";
    defparam rpll_inst.DYN_DA_EN = "true";
    defparam rpll_inst.DUTYDA_SEL = "1000";
    defparam rpll_inst.CLKOUT_FT_DIR = 1'b1;
    defparam rpll_inst.CLKOUTP_FT_DIR = 1'b1;
    defparam rpll_inst.CLKOUT_DLY_STEP = 0;
    defparam rpll_inst.CLKOUTP_DLY_STEP = 0;
    defparam rpll_inst.CLKFB_SEL = "internal";
    defparam rpll_inst.CLKOUT_BYPASS = "false";
    defparam rpll_inst.CLKOUTP_BYPASS = "false";
    defparam rpll_inst.CLKOUTD_BYPASS = "false";
    defparam rpll_inst.DYN_SDIV_SEL = 2;
    defparam rpll_inst.CLKOUTD_SRC = "CLKOUT";
    defparam rpll_inst.CLKOUTD3_SRC = "CLKOUT";
    defparam rpll_inst.DEVICE = "GW1NR-9C";
endmodule


// =============================================================================
// Gowin CLKDIV ÷5: clk_5x → pixclk
// Why hardware CLKDIV (not "always @(posedge) toggle"): it stays phase-aligned
// with FCLK inside the I/O SERDES path. A fabric divider would drift relative
// to OSER10 and corrupt the bit stream.
// =============================================================================
module Gowin_CLKDIV (
    output clkout,
    input  hclkin,
    input  resetn
);
    wire gw_gnd = 1'b0;

    CLKDIV clkdiv_inst (
        .CLKOUT(clkout),
        .HCLKIN(hclkin),
        .RESETN(resetn),
        .CALIB(gw_gnd)
    );
    defparam clkdiv_inst.DIV_MODE = "5";
    defparam clkdiv_inst.GSREN = "false";
endmodule
