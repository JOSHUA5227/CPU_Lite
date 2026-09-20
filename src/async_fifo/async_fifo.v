module async_fifo #(
    parameter WIDTH = 4,
    parameter DEPTH = 8
)(
    rclk,
    wclk,
    w_rst_n,
    r_rst_n,
    r_data,
    w_data,
    r_en,
    w_en,
    full,
    empty
);

localparam ADDR_WIDTH = $clog2(DEPTH);
localparam PTR_WIDTH  = ADDR_WIDTH + 1;


/* ============================================================
 * PORTS
 * ============================================================ */

input wire rclk;
input wire wclk;

input wire w_rst_n;
input wire r_rst_n;

input wire r_en;
input wire w_en;

input wire [WIDTH-1:0] w_data;

output wire [WIDTH-1:0] r_data;

output wire full;
output wire empty;


/* ============================================================
 * POINTERS
 * ============================================================ */

/*
 * Binary pointers are maintained locally in their own
 * clock domains.
 *
 * w_ptr  -> write domain
 * r_ptr  -> read domain
 */

wire [PTR_WIDTH-1:0] w_ptr;
wire [PTR_WIDTH-1:0] r_ptr;

wire [PTR_WIDTH-1:0] w_ptr_gray;
wire [PTR_WIDTH-1:0] r_ptr_gray;


/* ============================================================
 * SYNCHRONIZED GRAY POINTERS
 * ============================================================ */

/*
 * r_ptr_gray crosses from the read clock domain
 * into the write clock domain.
 *
 * w_ptr_gray crosses from the write clock domain
 * into the read clock domain.
 */

wire [PTR_WIDTH-1:0] sync_r_ptr_gray;
wire [PTR_WIDTH-1:0] sync_w_ptr_gray;


/* ============================================================
 * READ POINTER -> WRITE DOMAIN
 * ============================================================ */

sync_multi #(
    .WIDTH(PTR_WIDTH)
) sync_r (
    .clk(wclk),
    .rst_n(w_rst_n),
    .din(r_ptr_gray),
    .dout(sync_r_ptr_gray)
);


/* ============================================================
 * WRITE POINTER -> READ DOMAIN
 * ============================================================ */

sync_multi #(
    .WIDTH(PTR_WIDTH)
) sync_w (
    .clk(rclk),
    .rst_n(r_rst_n),
    .din(w_ptr_gray),
    .dout(sync_w_ptr_gray)
);


/* ============================================================
 * WRITE CONTROL
 * ============================================================ */

fifo_write #(
    .DEPTH(DEPTH)
) w1 (
    .clk(wclk),
    .rst_n(w_rst_n),
    .w_en(w_en),
    .sync_r_ptr_gray(sync_r_ptr_gray),
    .full(full),
    .w_ptr(w_ptr),
    .w_ptr_gray(w_ptr_gray)
);


/* ============================================================
 * READ CONTROL
 * ============================================================ */

fifo_read #(
    .DEPTH(DEPTH)
) r1 (
    .clk(rclk),
    .rst_n(r_rst_n),
    .r_en(r_en),
    .sync_w_ptr_gray(sync_w_ptr_gray),
    .empty(empty),
    .r_ptr(r_ptr),
    .r_ptr_gray(r_ptr_gray)
);


/* ============================================================
 * MEMORY
 * ============================================================ */

mem #(
    .WIDTH(WIDTH),
    .DEPTH(DEPTH)
) m1 (
    .w_clk(wclk),
    .r_clk(rclk),

    .w_en(w_en && !full),
    .r_en(r_en && !empty),

    .w_data(w_data),
    .r_data(r_data),

    .w_addr(w_ptr[ADDR_WIDTH-1:0]),
    .r_addr(r_ptr[ADDR_WIDTH-1:0])
);

endmodule
