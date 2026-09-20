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
    empty,
    r_full,
    fifo_count
);

localparam ADDR_WIDTH = $clog2(DEPTH);
localparam PTR_WIDTH  = ADDR_WIDTH + 1;

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

output wire [3:0] fifo_count;

output wire r_full;
/* ============================================================
 *  * POINTERS
 *   * ============================================================ */

wire [PTR_WIDTH-1:0] r_ptr;
wire [PTR_WIDTH-1:0] w_ptr;

wire [PTR_WIDTH-1:0] r_ptr_gray;
wire [PTR_WIDTH-1:0] w_ptr_gray;


/* ============================================================
 *  * SYNCHRONIZED POINTERS
 *   * ============================================================ */

wire [PTR_WIDTH-1:0] sync_r_ptr_gray;
wire [PTR_WIDTH-1:0] sync_w_ptr_gray;

wire [PTR_WIDTH-1:0] sync_r_ptr;
wire [PTR_WIDTH-1:0] sync_w_ptr;


/* ============================================================
 *  * FIFO COUNT
 *   * ============================================================ */

wire [PTR_WIDTH:0] fifo_count_full;
assign r_full = (sync_w_ptr == {~r_ptr[PTR_WIDTH-1], r_ptr[PTR_WIDTH-2:0]});


/* ============================================================
 *  * BINARY -> GRAY
 *   * ============================================================ */

b2g #(
    .WIDTH(PTR_WIDTH)
) g_r (
    .inp(r_ptr),
    .outp(r_ptr_gray)
);

b2g #(
    .WIDTH(PTR_WIDTH)
) g_w (
    .inp(w_ptr),
    .outp(w_ptr_gray)
);


/* ============================================================
 *  * READ POINTER -> WRITE DOMAIN
 *   * ============================================================ */

sync_multi #(
    .WIDTH(PTR_WIDTH)
) sync_r (
    .clk(wclk),
    .rst_n(w_rst_n),
    .din(r_ptr_gray),
    .dout(sync_r_ptr_gray)
);


/* ============================================================
 *  * WRITE POINTER -> READ DOMAIN
 *   * ============================================================ */

sync_multi #(
    .WIDTH(PTR_WIDTH)
) sync_w (
    .clk(rclk),
    .rst_n(r_rst_n),
    .din(w_ptr_gray),
    .dout(sync_w_ptr_gray)
);


/* ============================================================
 *  * GRAY -> BINARY
 *   * ============================================================ */

g2b #(
    .WIDTH(PTR_WIDTH)
) b_r (
    .inp(sync_r_ptr_gray),
    .outp(sync_r_ptr)
);

g2b #(
    .WIDTH(PTR_WIDTH)
) b_w (
    .inp(sync_w_ptr_gray),
    .outp(sync_w_ptr)
);


/* ============================================================
 *  * WRITE CONTROL
 *   * ============================================================ */

fifo_write #(
    .DEPTH(DEPTH)
) w1 (
    .clk(wclk),
    .rst_n(w_rst_n),
    .w_en(w_en),
    .full(full),
    .w_ptr(w_ptr),
    .sync_r_ptr(sync_r_ptr)
);


/* ============================================================
 *  * READ CONTROL
 *   * ============================================================ */

fifo_read #(
    .DEPTH(DEPTH)
) r1 (
    .clk(rclk),
    .rst_n(r_rst_n),
    .r_en(r_en),
    .empty(empty),
    .r_ptr(r_ptr),
    .sync_w_ptr(sync_w_ptr)
);


/* ============================================================
 *  * FIFO COUNT
 *   *
 *    * The pointer subtraction is PTR_WIDTH bits wide.
 *     * Only the lower four bits are exposed as the FIFO count.
 *      *
 *       * For DEPTH = 8, valid FIFO counts are 0 through 8.
 *        * ============================================================ */

assign fifo_count_full = {1'b0,sync_w_ptr} - {1'b0,r_ptr};
assign fifo_count = fifo_count_full[3:0];

/* ============================================================
 *  * MEMORY
 *   * ============================================================ */

mem #(
    .WIDTH(WIDTH),
    .DEPTH(DEPTH)
) m1 (
    .w_clk(wclk),
    .r_clk(rclk),

    .w_en(w_en && !full),

    .w_data(w_data),
    .r_data(r_data),

    .w_addr(w_ptr[ADDR_WIDTH-1:0]),
    .r_addr(r_ptr[ADDR_WIDTH-1:0])
);

endmodule
