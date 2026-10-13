module cpu_interface #(
    parameter PROG_ADDR_WIDTH = 12,
    parameter DATA_ADDR_WIDTH = 14,
    parameter DATA_WIDTH      = 32,
    parameter CACHE_LINES     = 8,
    parameter WORDS_PER       = 4
)(
    input wire fast_clk,
    input wire slow_clk,
    input wire rst_n,

    // PROGRAM MEMORY PORTS
    output wire [PROG_ADDR_WIDTH-1:0] cpu_pc,
    input  wire [DATA_WIDTH-1:0] instruction,
    input  wire [PROG_ADDR_WIDTH-1:0] instruct_addr,
    output wire read_en,

    // DATA MEMORY PORTS
    output wire [DATA_ADDR_WIDTH-1:0] mem_addr,
    output wire [DATA_WIDTH-1:0]      mem_wdata,
    output wire mem_read_en,
    output wire mem_write_en,

    input wire [DATA_WIDTH-1:0] mem_rdata,
    input wire mem_rvalid
);

    // ============================================================
    // RESET SYNCHRONIZERS
    // ============================================================

    wire fast_rst_n;
    wire slow_rst_n;

    reset_sync u_fast_reset_sync (
        .clk       (fast_clk),
        .rst_n     (rst_n),
        .new_reset (fast_rst_n)
    );

    reset_sync u_slow_reset_sync (
        .clk       (slow_clk),
        .rst_n     (rst_n),
        .new_reset (slow_rst_n)
    );

    // ============================================================
    // FIFO PARAMETERS
    // ============================================================

    localparam REQ_FIFO_WIDTH =
        DATA_ADDR_WIDTH + DATA_WIDTH + 1;

    localparam RESP_FIFO_WIDTH = DATA_WIDTH;

    // ============================================================
    // CPU <-> CACHE
    // ============================================================

    wire [DATA_WIDTH-1:0] cpu_rdata;
    wire cpu_ready;

    wire cpu_req;
    wire cpu_read_write;
    wire [DATA_ADDR_WIDTH-1:0] cpu_addr;
    wire [DATA_WIDTH-1:0] cpu_wdata;

    // ============================================================
    // CACHE <-> REQUEST FIFO
    // ============================================================

    wire [REQ_FIFO_WIDTH-1:0] cache_req_data;
    wire cache_req_en;
    wire req_fifo_full;

    wire [REQ_FIFO_WIDTH-1:0] req_fifo_rdata;
    wire req_fifo_r_en;
    wire req_fifo_empty;

    // ============================================================
    // CACHE <-> RESPONSE FIFO
    // ============================================================

    wire [DATA_WIDTH-1:0] cache_resp_data;
    wire cache_resp_en;
    wire resp_fifo_empty;

    wire [DATA_WIDTH-1:0] resp_fifo_wdata;
    wire resp_fifo_w_en;
    wire resp_fifo_full;

    // ============================================================
    // CPU CORE - FAST DOMAIN
    // ============================================================

    cpu_core_pipelined #(
        .PROG_ADDR_WIDTH(PROG_ADDR_WIDTH),
        .DATA_ADDR_WIDTH(DATA_ADDR_WIDTH),
        .DATA_WIDTH(DATA_WIDTH)
    ) u_cpu_core (
        .clk           (fast_clk),
        .rst_n         (fast_rst_n),

        .instruction   (instruction),
        .instruct_addr   (instruct_addr),
        .pc            (cpu_pc),
        .read_en       (read_en),

        .rdata         (cpu_rdata),
        .cpu_ready     (cpu_ready),

        .cpu_req       (cpu_req),
        .read_write    (cpu_read_write),
        .addr          (cpu_addr),
        .wdata         (cpu_wdata)
    );

    // ============================================================
    // L1 CACHE - FAST DOMAIN
    // ============================================================

    cache #(
        .ADDR_WIDTH  (DATA_ADDR_WIDTH),
        .DATA_WIDTH  (DATA_WIDTH),
        .CACHE_LINES (CACHE_LINES),
        .WORDS_PER   (WORDS_PER)
    ) u_cache (
        .clk              (fast_clk),
        .rst_n            (fast_rst_n),

        .cpu_req          (cpu_req),
        .read_write       (cpu_read_write),
        .addr             (cpu_addr),
        .wdata            (cpu_wdata),

        .rdata            (cpu_rdata),
        .cpu_ready        (cpu_ready),

        .fifo_req_full    (req_fifo_full),
        .fifo_req_data    (cache_req_data),
        .fifo_req_en      (cache_req_en),

        .fifo_resp_en     (cache_resp_en),
        .fifo_resp_data   (cache_resp_data),
        .fifo_resp_empty  (resp_fifo_empty)
    );

    // ============================================================
    // REQUEST ASYNC FIFO
    // Write: FAST DOMAIN
    // Read : SLOW DOMAIN
    // ============================================================

    async_fifo #(
        .WIDTH(REQ_FIFO_WIDTH),
        .DEPTH(WORDS_PER)
    ) u_request_fifo (
        .rclk    (slow_clk),
        .wclk    (fast_clk),

        .w_rst_n (fast_rst_n),
        .r_rst_n (slow_rst_n),

        .r_data  (req_fifo_rdata),
        .w_data  (cache_req_data),

        .r_en    (req_fifo_r_en),
        .w_en    (cache_req_en),

        .full    (req_fifo_full),
        .empty   (req_fifo_empty)
    );

    // ============================================================
    // RESPONSE ASYNC FIFO
    // Write: SLOW DOMAIN
    // Read : FAST DOMAIN
    // ============================================================

    async_fifo #(
        .WIDTH(RESP_FIFO_WIDTH),
        .DEPTH(WORDS_PER)
    ) u_response_fifo (
        .rclk    (fast_clk),
        .wclk    (slow_clk),

        .w_rst_n (slow_rst_n),
        .r_rst_n (fast_rst_n),

        .r_data  (cache_resp_data),
        .w_data  (resp_fifo_wdata),

        .r_en    (cache_resp_en),
        .w_en    (resp_fifo_w_en),

        .full    (resp_fifo_full),
        .empty   (resp_fifo_empty)
    );

    // ============================================================
    // MEMORY CONTROLLER - SLOW DOMAIN
    // ============================================================

    memory_controller #(
        .ADDR_WIDTH(DATA_ADDR_WIDTH),
        .DATA_WIDTH(DATA_WIDTH)
    ) u_memory_controller (
        .clk       (slow_clk),
        .rst_n     (slow_rst_n),

        .req_data  (req_fifo_rdata),
        .req_empty (req_fifo_empty),
        .req_en    (req_fifo_r_en),

        .resp_data (resp_fifo_wdata),
        .resp_en   (resp_fifo_w_en),
        .resp_full (resp_fifo_full),

        .mem_addr     (mem_addr),
        .mem_wdata    (mem_wdata),
        .mem_read_en  (mem_read_en),
        .mem_write_en (mem_write_en),

        .mem_rdata    (mem_rdata),
        .mem_rvalid   (mem_rvalid)
    );

endmodule
