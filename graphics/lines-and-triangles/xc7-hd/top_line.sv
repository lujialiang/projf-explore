// Project F: Lines and Triangles - Top Line (Nexys Video)
// (C)2021 Will Green, open source hardware released under the MIT License
// Learn more at https://projectf.io

`default_nettype none
`timescale 1ns / 1ps

module top_line (
    input  wire logic clk_100m,         // 100 MHz clock
    input  wire logic btn_rst,          // reset button (active low)
    output      logic hdmi_tx_ch0_p,    // HDMI source channel 0 diff+
    output      logic hdmi_tx_ch0_n,    // HDMI source channel 0 diff-
    output      logic hdmi_tx_ch1_p,    // HDMI source channel 1 diff+
    output      logic hdmi_tx_ch1_n,    // HDMI source channel 1 diff-
    output      logic hdmi_tx_ch2_p,    // HDMI source channel 2 diff+
    output      logic hdmi_tx_ch2_n,    // HDMI source channel 2 diff-
    output      logic hdmi_tx_clk_p,    // HDMI source clock diff+
    output      logic hdmi_tx_clk_n     // HDMI source clock diff-
    );

    // generate pixel clocks
    logic clk_pix;                  // pixel clock
    logic clk_pix_5x;               // 5x pixel clock for 10:1 DDR SerDes
    logic clk_pix_locked;           // pixel clock locked?
    clock_gen_720p clock_pix_inst (
        .clk_100m,
        .rst(!btn_rst),             // reset button is active low
        .clk_pix,
        .clk_pix_5x,
        .clk_pix_locked
    );

    // display sync signals and coordinates
    localparam CORDW = 16;
    logic hsync, vsync;
    logic de, frame, line;
    display_720p #(.CORDW(CORDW)) display_inst (
        .clk_pix,
        .rst_pix(!clk_pix_locked),
        /* verilator lint_off PINCONNECTEMPTY */
        .sx(),
        .sy(),
        /* verilator lint_on PINCONNECTEMPTY */
        .hsync,
        .vsync,
        .de,
        .frame,
        .line
    );

    logic frame_sys;  // start of new frame in system clock domain
    xd xd_frame (.clk_i(clk_pix), .clk_o(clk_100m),
                 .rst_i(1'b0), .rst_o(1'b0), .i(frame), .o(frame_sys));

    // framebuffer (FB)
    localparam FB_WIDTH   = 640;
    localparam FB_HEIGHT  = 360;
    localparam FB_CIDXW   = 4;
    localparam FB_CHANW   = 4;
    localparam FB_SCALE   = 2;
    localparam FB_IMAGE   = "";
    localparam FB_PALETTE = "16_colr_4bit_palette.mem";

    logic fb_we;  // write enable
    logic signed [CORDW-1:0] fbx, fby;  // draw coordinates
    logic [FB_CIDXW-1:0] fb_cidx;  // draw colour index
    logic fb_busy;  // when framebuffer is busy it cannot accept writes
    logic [FB_CHANW-1:0] fb_red, fb_green, fb_blue;  // colours for display output

    framebuffer_bram #(
        .WIDTH(FB_WIDTH),
        .HEIGHT(FB_HEIGHT),
        .CIDXW(FB_CIDXW),
        .CHANW(FB_CHANW),
        .SCALE(FB_SCALE),
        .F_IMAGE(FB_IMAGE),
        .F_PALETTE(FB_PALETTE)
    ) fb_inst (
        .clk_sys(clk_100m),
        .clk_pix,
        .rst_sys(1'b0),
        .rst_pix(1'b0),
        .de,
        .frame,
        .line,
        .we(fb_we),
        .x(fbx),
        .y(fby),
        .cidx(fb_cidx),
        /* verilator lint_off PINCONNECTEMPTY */
        .clip(),
        /* verilator lint_on PINCONNECTEMPTY */
        .busy(fb_busy),
        .red(fb_red),
        .green(fb_green),
        .blue(fb_blue)
    );

    // draw line in framebuffer
    logic signed [CORDW-1:0] vx0, vy0, vx1, vy1;  // line coords
    logic draw_start, drawing, draw_done;  // drawing signals

    // draw state machine
    enum {IDLE, INIT, DRAW, DONE} state;
    always_ff @(posedge clk_100m) begin
        case (state)
            INIT: begin  // register coordinates and colour
                vx0 <= 140; vy0 <=   0;
                vx1 <= 499; vy1 <= 359;
                fb_cidx <= 4'h9;  // orange
                draw_start <= 1;
                state <= DRAW;
            end
            DRAW: begin
                draw_start <= 0;
                if (draw_done) state <= DONE;
            end
            DONE: state <= DONE;
            default: if (frame_sys) state <= INIT;  // IDLE
        endcase
    end

    draw_line #(.CORDW(CORDW)) draw_line_inst (
        .clk(clk_100m),
        .rst(1'b0),
        .start(draw_start),
        .oe(!fb_busy),  // draw when FB is available
        .x0(vx0),
        .y0(vy0),
        .x1(vx1),
        .y1(vy1),
        .x(fbx),
        .y(fby),
        .drawing,
        /* verilator lint_off PINCONNECTEMPTY */
        .busy(),
        /* verilator lint_on PINCONNECTEMPTY */
        .done(draw_done)
    );

    // write to framebuffer when drawing
    always_comb fb_we = drawing;

    // reading from FB takes one cycle: delay display signals to match
    logic hsync_p1, vsync_p1, de_p1;
    always_ff @(posedge clk_pix) begin
        hsync_p1 <= hsync;
        vsync_p1 <= vsync;
        de_p1 <= de;
    end

    // DVI signals
    logic [7:0] dvi_red, dvi_green, dvi_blue;
    logic dvi_hsync, dvi_vsync, dvi_de;
    always_ff @(posedge clk_pix) begin
        dvi_hsync <= hsync_p1;
        dvi_vsync <= vsync_p1;
        dvi_de    <= de_p1;
        dvi_red   <= {2{fb_red}};
        dvi_green <= {2{fb_green}};
        dvi_blue  <= {2{fb_blue}};
    end

    // TMDS encoding and serialization
    logic tmds_ch0_serial, tmds_ch1_serial, tmds_ch2_serial, tmds_clk_serial;
    dvi_generator dvi_out (
        .clk_pix,
        .clk_pix_5x,
        .rst_pix(!clk_pix_locked),
        .de(dvi_de),
        .data_in_ch0(dvi_blue),
        .data_in_ch1(dvi_green),
        .data_in_ch2(dvi_red),
        .ctrl_in_ch0({dvi_vsync, dvi_hsync}),
        .ctrl_in_ch1(2'b00),
        .ctrl_in_ch2(2'b00),
        .tmds_ch0_serial,
        .tmds_ch1_serial,
        .tmds_ch2_serial,
        .tmds_clk_serial
    );

    // TMDS output pins
    tmds_out tmds_ch0 (.tmds(tmds_ch0_serial),
        .pin_p(hdmi_tx_ch0_p), .pin_n(hdmi_tx_ch0_n));
    tmds_out tmds_ch1 (.tmds(tmds_ch1_serial),
        .pin_p(hdmi_tx_ch1_p), .pin_n(hdmi_tx_ch1_n));
    tmds_out tmds_ch2 (.tmds(tmds_ch2_serial),
        .pin_p(hdmi_tx_ch2_p), .pin_n(hdmi_tx_ch2_n));
    tmds_out tmds_clk (.tmds(tmds_clk_serial),
        .pin_p(hdmi_tx_clk_p), .pin_n(hdmi_tx_clk_n));
endmodule
