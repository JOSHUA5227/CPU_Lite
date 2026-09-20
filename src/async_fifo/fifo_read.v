module fifo_read #(
    parameter DEPTH = 8
)(
    clk,
    rst_n,
    r_en,
    sync_w_ptr_gray,
    empty,
    r_ptr,
    r_ptr_gray
);

localparam ADDR_WIDTH = $clog2(DEPTH);
localparam PTR_WIDTH  = ADDR_WIDTH + 1;

input wire clk;
input wire rst_n;
input wire r_en;

input wire [PTR_WIDTH-1:0] sync_w_ptr_gray;

output wire empty;
output reg [PTR_WIDTH-1:0] r_ptr;
output wire [PTR_WIDTH-1:0] r_ptr_gray;

assign r_ptr_gray = r_ptr ^ (r_ptr >> 1);

assign empty = (r_ptr_gray == sync_w_ptr_gray);

always @(posedge clk or negedge rst_n)
begin
    if(!rst_n)
        r_ptr <= 0;
    else if(r_en && !empty)
        r_ptr <= r_ptr + 1'b1;
end

endmodule
