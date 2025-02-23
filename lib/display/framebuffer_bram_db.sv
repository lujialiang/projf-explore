// Project F Library - Double-Buffered Framebuffer in BRAM (Indexed Colour)
// (C)2022 Will Green, Open Source Hardware released under the MIT License
// Learn more at https://projectf.io

`default_nettype none
`timescale 1ns / 1ps

// NB. Signals are in clk_sys domain unless indicated

module framebuffer_bram_db #(
    parameter CORDW=16,      // signed coordinate width (bits)
    parameter WIDTH=320,     // width of framebuffer in pixels
    parameter HEIGHT=180,    // height of framebuffer in pixels
    parameter CIDXW=4,       // colour index data width: 4=16, 8=256 colours
    parameter CHANW=4,       // width of RGB colour channels (4 or 8 bit)
    parameter SCALE=4,       // display output scaling factor (>=1)
    parameter F_IMAGE="",    // image file to load into framebuffer
    parameter F_PALETTE=""   // palette file to load into CLUT
    ) (
    input  wire logic clk_sys,    // system clock
    input  wire logic clk_pix,    // pixel clock
    input  wire logic rst_sys,    // reset (clk_sys)
    input  wire logic rst_pix,    // reset (clk_pix)
    input  wire logic de,         // data enable for display (clk_pix)
    input  wire logic frame,      // start a new frame (clk_pix)
    input  wire logic line,       // start a new screen line (clk_pix)
    input  wire logic we,         // write enable
    input  wire logic signed [CORDW-1:0] x,  // horizontal pixel coordinate
    input  wire logic signed [CORDW-1:0] y,  // vertical pixel coordinate
    input  wire logic [CIDXW-1:0] cidx,   // framebuffer colour index
    input  wire logic [CIDXW-1:0] bgidx,  // framebuffer background colour index
    input  wire logic clear,              // clear write buffer on frame start
    output      logic busy,               // busy with reading for display output
    output      logic wready,             // ready to accept writes (after clear)
    output      logic clip,               // pixel coordinate outside buffer
    output      logic [CHANW-1:0] red,    // colour output to display (clk_pix)
    output      logic [CHANW-1:0] green,  //     "    "    "    "    "
    output      logic [CHANW-1:0] blue    //     "    "    "    "    "
    );

    logic frame_sys;  // start of new frame in system clock domain
    xd xd_frame (.clk_i(clk_pix), .clk_o(clk_sys),
                 .rst_i(rst_pix), .rst_o(rst_sys), .i(frame), .o(frame_sys));

    // buffer selection
    logic front_buf;
    always_ff @(posedge clk_sys) begin
        if (frame_sys) front_buf <= ~front_buf;  // swap every frame
        if (rst_sys) front_buf <= 0;
    end

    // framebuffer (FB)
    localparam FB_PIXELS   = WIDTH * HEIGHT;
    localparam FB_BUFSIZE  = 2 ** $clog2(FB_PIXELS+1);  // align buffers to power-of-two
    localparam FB_DEPTH    = 2 * FB_BUFSIZE;
    localparam FB_ADDRW    = $clog2(FB_BUFSIZE);
    localparam FB_DATAW    = CIDXW;
    localparam FB_DUALPORT = 1;  // separate read and write ports?

    logic [FB_ADDRW-1:0] fb_addr_read, fb_addr_write;
    logic [FB_DATAW-1:0] fb_cidx_read, fb_cidx_read_p1;

    // write address components
    logic signed [CORDW-1:0] x_add;  // pixel position on line
    logic signed[FB_ADDRW-1:0] fb_addr_line;  // address of line for drawing
    logic [FB_ADDRW-1:0] fb_addr_clr, fb_addr_clr_p1;  // address for clearing screen

    // write state machine
    enum {IDLE, INIT, CLR, WAIT, ACTIVE} wstate;
    always_ff @(posedge clk_sys) begin
        case (wstate)
            INIT: begin
                wstate <= (clear) ? CLR : ACTIVE;
                fb_addr_clr_p1 <= 0;
            end
            CLR: begin  // clear whole buffer
                if (fb_addr_clr_p1 == FB_BUFSIZE-1) wstate <= WAIT;
                fb_addr_clr_p1 <= fb_addr_clr_p1 + 1;
            end
            WAIT: wstate <= ACTIVE;  // one cycle of latency before becoming active
            default: if (frame_sys) wstate <= INIT;  // IDLE or ACTIVE
        endcase
        if (rst_sys) wstate <= IDLE;
    end

    // ready for drawing to begin
    always_comb wready = (wstate == ACTIVE);

    // calculate write address from pixel coordinates (three stages: mul, add, clear mux)
    always_ff @(posedge clk_sys) begin
        /* verilator lint_off WIDTH */
        // first stage
        fb_addr_clr <= fb_addr_clr_p1;
        fb_addr_line <= WIDTH * y;  // write address 1st stage (y could be negative)
        x_add <= x;  // save x for write address 2nd stage
        // second stage
        fb_addr_write <= (wready) ? fb_addr_line + x_add : fb_addr_clr;
        /* verilator lint_on WIDTH */
    end

    // draw colour and write enable (delay to match address calculation)
    logic fb_we, we_in_p1;
    logic [FB_DATAW-1:0] fb_cidx_write, cidx_in_p1;
    always_ff @(posedge clk_sys) begin
        // first stage
        we_in_p1 <= ((we && wready) || wstate == CLR);  // draw or clear enables write
        cidx_in_p1 <= (wstate == CLR) ? bgidx : cidx;    // which draw colour?
        clip <= (wstate == ACTIVE) && (y < 0 || y >= HEIGHT || x < 0 || x >= WIDTH);  // clipped?
        // second stage
        fb_we <= (busy || clip) ? 0 : we_in_p1;  // write if neither busy nor clipped
        fb_cidx_write <= cidx_in_p1;
    end

    // framebuffer memory (BRAM)
    bram_sdp #(
        .WIDTH(FB_DATAW),
        .DEPTH(FB_DEPTH),
        .INIT_F(F_IMAGE)
    ) bram_inst (
        .clk_write(clk_sys),
        .clk_read(clk_sys),
        .we(fb_we),
        .addr_write({~front_buf,fb_addr_write}),
        .addr_read({front_buf,fb_addr_read}),
        .data_in(fb_cidx_write),
        .data_out(fb_cidx_read)
    );

    // linebuffer (LB)
    localparam LB_SCALE = SCALE;  // scale (horizontal and vertical)
    localparam LB_LEN   = WIDTH;  // line length matches framebuffer
    localparam LB_BPC   = CHANW;  // bits per colour channel

    logic lb_data_req;  // LB requesting data
    logic [$clog2(LB_LEN+1)-1:0] cnt_h;  // count pixels in line to read

    // LB enable (not corrected for latency)
    logic lb_en_in, lb_en_out;
    always_comb lb_en_in  = cnt_h < LB_LEN;
    always_comb lb_en_out = de;

    // LB enable in: BRAM, address calc, and CLUT reg add three cycles of latency
    localparam LAT = 3;  // write latency
    logic [LAT-1:0] lb_en_in_sr;
    always_ff @(posedge clk_sys) begin
        lb_en_in_sr <= {lb_en_in, lb_en_in_sr[LAT-1:1]};
        if (rst_sys) lb_en_in_sr <= 0;
    end

    // Load data from FB into LB
    always_ff @(posedge clk_sys) begin
        if (fb_addr_read < FB_PIXELS-1) begin
            if (lb_data_req) begin
                cnt_h <= 0;  // start new line
                if (!FB_DUALPORT) busy <= 1;    // set busy flag if not dual port
            end else if (cnt_h < LB_LEN) begin  // advance to start of next line
                cnt_h <= cnt_h + 1;
                fb_addr_read <= fb_addr_read + 1;
            end
        end else cnt_h <= LB_LEN;
        if (frame_sys) begin
            fb_addr_read <= 0;  // new frame
            busy <= 0;  // LB reads don't cross frame boundary
        end
        if (rst_sys) begin
            fb_addr_read <= 0;
            busy <= 0;
            cnt_h <= LB_LEN;  // don't start reading after reset
        end
        if (lb_en_in_sr == 3'b100) busy <= 0;  // LB read done: match latency `LAT`
    end

    // LB colour channels
    logic [LB_BPC-1:0] lb_in_0,  lb_in_1,  lb_in_2;
    logic [LB_BPC-1:0] lb_out_0, lb_out_1, lb_out_2;

    linebuffer #(
        .WIDTH(LB_BPC),   // data width of each channel
        .LEN(LB_LEN),     // length of line
        .SCALE(LB_SCALE)  // scaling factor (>=1)
        ) lb_inst (
        .clk_in(clk_sys),        // input clock
        .clk_out(clk_pix),       // output clock
        .rst_in(rst_sys),        // reset (clk_in)
        .rst_out(rst_pix),       // reset (clk_out)
        .data_req(lb_data_req),  // request input data (clk_in)
        .en_in(lb_en_in_sr[0]),  // enable input (clk_in)
        .en_out(lb_en_out),      // enable output (clk_out)
        .frame,                  // start a new frame (clk_out)
        .line,                   // start a new line (clk_out)
        .din_0(lb_in_0),         // data in (clk_in)
        .din_1(lb_in_1),
        .din_2(lb_in_2),
        .dout_0(lb_out_0),       // data out (clk_out)
        .dout_1(lb_out_1),
        .dout_2(lb_out_2)
    );

    // improve timing with register between BRAM and async ROM
    always_ff @(posedge clk_sys) fb_cidx_read_p1 <= fb_cidx_read;

    // colour lookup table (ROM)
    localparam CLUTW = 3 * CHANW;
    logic [CLUTW-1:0] clut_colr;
    rom_async #(
        .WIDTH(CLUTW),
        .DEPTH(2**CIDXW),
        .INIT_F(F_PALETTE)
    ) clut (
        .addr(fb_cidx_read_p1),
        .data(clut_colr)
    );

    // map colour index to palette using CLUT and read into LB
    always_ff @(posedge clk_sys) {lb_in_2, lb_in_1, lb_in_0} <= clut_colr;

    logic lb_en_out_p1;  // LB enable out: reading from LB BRAM takes one cycle
    always_ff @(posedge clk_pix) lb_en_out_p1 <= lb_en_out;

    // colour output - combinational because top module should register
    always_comb begin
        red   = lb_en_out_p1 ? lb_out_2 : 0;
        green = lb_en_out_p1 ? lb_out_1 : 0;
        blue  = lb_en_out_p1 ? lb_out_0 : 0;
    end
endmodule
