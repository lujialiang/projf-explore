// Project F: Lines and Triangles - Demo (Verilator SDL)
// (C)2022 Will Green, open source hardware released under the MIT License
// Learn more at https://projectf.io/posts/hardware-sprites/

`default_nettype none
`timescale 1ns / 1ps

module top_demo #(parameter CORDW=16) (  // signed coordinate width (bits)
    input  wire logic clk_pix,      // pixel clock
    input  wire logic rst_pix,      // sim reset
    output      logic signed [CORDW-1:0] sdl_sx,  // horizontal SDL position
    output      logic signed [CORDW-1:0] sdl_sy,  // vertical SDL position
    output      logic sdl_de,       // data enable (low in blanking interval)
    output      logic sdl_frame,    // high at start of frame
    output      logic [7:0] sdl_r,  // 8-bit red
    output      logic [7:0] sdl_g,  // 8-bit green
    output      logic [7:0] sdl_b   // 8-bit blue
    );

    // system clock is the same as pixel clock in simulation
    logic clk_sys, rst_sys;
    always_comb begin
        clk_sys = clk_pix;
        rst_sys = rst_pix;
    end

    // display sync signals and coordinates
    logic signed [CORDW-1:0] sx, sy;
    logic de, frame, line;
    display_480p #(.CORDW(CORDW)) display_inst (
        .clk_pix,
        .rst_pix,
        .sx,
        .sy,
        /* verilator lint_off PINCONNECTEMPTY */
        .hsync(),
        .vsync(),
        /* verilator lint_on PINCONNECTEMPTY */
        .de,
        .frame,
        .line
    );

    // framebuffer display settings
    localparam FB_SCALE =  2;  // framebuffer scaling via linebuffer (1-63)
    localparam FB_OFFX  =  0;  // horizontal offset
    localparam FB_OFFY  = 60;  // vertical offset

    // display signals in system domain
    logic frame_sys, line_sys, lb_line, lb_first;
    xd xd_frame (.clk_i(clk_pix), .clk_o(clk_sys), .rst_i(rst_pix), .rst_o(rst_sys),
                    .i(frame), .o(frame_sys));
    xd xd_line  (.clk_i(clk_pix), .clk_o(clk_sys), .rst_i(rst_pix), .rst_o(rst_sys),
                    .i(line), .o(line_sys));
    xd xd_read  (.clk_i(clk_pix), .clk_o(clk_sys), .rst_i(rst_pix), .rst_o(rst_sys),
                    .i(sy>=FB_OFFY), .o(lb_line));
    xd xd_start (.clk_i(clk_pix), .clk_o(clk_sys), .rst_i(rst_pix), .rst_o(rst_sys),
                    .i(sy==FB_OFFY), .o(lb_first));

    // colour parameters
    localparam CHANW = 4;        // colour channel width (bits)
    localparam COLRW = 3*CHANW;  // colour width: three channels (bits)
    localparam CIDXW = 4;        // colour index width (bits)
    localparam PAL_FILE = "../../../lib/res/palettes/sweetie16_4b.mem";  // palette file

    // framebuffer (FB)
    localparam FB_WIDTH  = 320;
    localparam FB_HEIGHT = 180;
    localparam FB_PIXELS = FB_WIDTH * FB_HEIGHT;  // total pixels in buffer
    localparam FB_ADDRW  = $clog2(FB_PIXELS);  // address width
    localparam FB_DATAW  = CIDXW;  // colour bits per pixel
    localparam FB_IMAGE  = "";  // bitmap file

    // pixel read and write addresses and colours
    logic fb_we;
    logic [FB_ADDRW-1:0] fb_addr_write, fb_addr_read;
    logic [FB_DATAW-1:0] fb_colr_write, fb_colr_read;

    // framebuffer memory
    bram_sdp #(
        .WIDTH(FB_DATAW),
        .DEPTH(FB_PIXELS),
        .INIT_F(FB_IMAGE)
    ) bram_inst (
        .clk_write(clk_sys),
        .clk_read(clk_sys),
        .we(fb_we),
        .addr_write(fb_addr_write),
        .addr_read(fb_addr_read),
        .data_in(fb_colr_write),
        .data_out(fb_colr_read)
    );

    // render line/cube/triangles
    logic drawing;  // actively drawing
    logic signed [CORDW-1:0] drx, dry;  // draw coordinates
    render_triangles #(  // switch module name to change demo
        .CORDW(CORDW),
        .CIDXW(CIDXW)
    ) render_instance (
        .clk(clk_sys),
        .rst(rst_sys),
        .oe(1'b1),
        .start(frame_sys),
        .x(drx),
        .y(dry),
        .cidx(fb_colr_write),
        .drawing,
        /* verilator lint_off PINCONNECTEMPTY */
        .done()
        /* verilator lint_on PINCONNECTEMPTY */
    );

    // calculate pixel address in framebuffer (two cycle latency)
    bitmap_addr #(
        .CORDW(CORDW),
        .ADDRW(FB_ADDRW)
    ) bitmap_addr_instance (
        .clk(clk_sys),
        .bmpw(FB_WIDTH),
        .bmph(FB_HEIGHT),
        .x(drx),
        .y(dry),
        .offx(0),
        .offy(0),
        .addr(fb_addr_write),
        /* verilator lint_off PINCONNECTEMPTY */
        .clip()
        /* verilator lint_on PINCONNECTEMPTY */
    );

    // delay write enable to match address calculation latency
    always_ff @(posedge clk_sys) fb_we <= drawing;

    // count lines for scaling via linebuffer
    logic [$clog2(FB_SCALE):0] cnt_lb_line;
    always_ff @(posedge clk_sys) begin
        if (line_sys) begin
            if (lb_first) cnt_lb_line <= 0;
            else cnt_lb_line <= (cnt_lb_line == FB_SCALE-1) ? 0 : cnt_lb_line + 1;
        end
    end

    // enable linebuffer input
    logic lb_en_in;
    always_comb lb_en_in = (lb_line && cnt_lb_line == 0 && cnt_lbx < FB_WIDTH);

    // calculate framebuffer read address for linebuffer
    logic [$clog2(FB_WIDTH)-1:0] cnt_lbx;
    always_ff @(posedge clk_sys) begin
        if (frame_sys) begin  // reset address at start of frame
            fb_addr_read <= 0;
        end else if (line_sys) begin  // reset horizontal counter at start of line
            cnt_lbx <= 0;
        end else if (lb_en_in) begin
            fb_addr_read <= fb_addr_read + 1;
            cnt_lbx <= cnt_lbx + 1;
        end
    end

    // enable linebuffer output
    logic lb_en_out;
    localparam LB_LAT = 3;  // output latency compensation: lb_en_out+1, LB+1, CLUT+1
    always_ff @(posedge clk_pix) begin
        lb_en_out <= (sy >= FB_OFFY && sy < (FB_HEIGHT * FB_SCALE) + FB_OFFY
            && sx >= FB_OFFX - LB_LAT && sx < (FB_WIDTH * FB_SCALE) + FB_OFFX - LB_LAT);
    end

    logic [FB_DATAW-1:0] lb_colr_out;
    linebuffer_simple #(
        .DATAW(CIDXW),
        .LEN(FB_WIDTH)
    ) linebuffer_instance (
        .clk_sys,
        .clk_pix,
        .line,
        .line_sys,
        .en_in(lb_en_in),  // should be in system clock domain
        .en_out(lb_en_out),
        .scale(FB_SCALE),
        .data_in(fb_colr_read),
        .data_out(lb_colr_out)
    );

    // colour lookup table
    logic [COLRW-1:0] fb_pix_colr;
    clut_simple #(
        .COLRW(COLRW),
        .CIDXW(CIDXW),
        .F_PAL(PAL_FILE)
        ) clut_instance (
        .clk_write(clk_pix),
        .clk_read(clk_pix),
        .we(0),
        .cidx_write(0),
        .cidx_read(lb_colr_out),
        .colr_in(0),
        .colr_out(fb_pix_colr)
    );

    // paint screen
    logic paint_area;  // area of screen to paint
    logic [CHANW-1:0] paint_r, paint_g, paint_b;  // colour channels
    always_comb begin
        paint_area = (sy >= FB_OFFY && sy < (FB_HEIGHT * FB_SCALE) + FB_OFFY
            && sx >= FB_OFFX && sx < FB_WIDTH * FB_SCALE + FB_OFFX);
        {paint_r, paint_g, paint_b} = (de && paint_area) ? fb_pix_colr: 12'h000;
    end

    // SDL output (8 bits per colour channel)
    always_ff @(posedge clk_pix) begin
        sdl_sx <= sx;
        sdl_sy <= sy;
        sdl_de <= de;
        sdl_frame <= frame;
        sdl_r <= {2{paint_r}};  // double signal width (assumes CHANW=4)
        sdl_g <= {2{paint_g}};
        sdl_b <= {2{paint_b}};
    end
endmodule
