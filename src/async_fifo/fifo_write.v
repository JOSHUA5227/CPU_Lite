module fifo_write #(
    parameter DEPTH = 8
)(
    clk,
    rst_n,
    w_en,
    sync_r_ptr_gray,
    full,
    w_ptr,
    w_ptr_gray
);

localparam ADDR_WIDTH = $clog2(DEPTH);
localparam PTR_WIDTH  = ADDR_WIDTH + 1;

input wire clk;
input wire rst_n;
input wire w_en;

input wire [PTR_WIDTH-1:0] sync_r_ptr_gray;

output wire full;
output reg [PTR_WIDTH-1:0] w_ptr;
output wire [PTR_WIDTH-1:0] w_ptr_gray;

assign w_ptr_gray = w_ptr ^ (w_ptr >> 1);

assign full = (w_ptr_gray == {~sync_r_ptr_gray[PTR_WIDTH-1:PTR_WIDTH-2],sync_r_ptr_gray[PTR_WIDTH-3:0]});

always @(posedge clk or negedge rst_n)
begin
    if(!rst_n)
    begin
        w_ptr <= 0;
    end
    else
    begin
        if(w_en && !full)
            w_ptr <= w_ptr + 1'b1;
    end
end

endmodule
