module fifo_read #(parameter DEPTH = 8)(
    clk,
    rst_n,
    r_en,
    empty,
    r_ptr,
    sync_w_ptr
);

localparam ADDR_WIDTH = $clog2(DEPTH);
localparam PTR_WIDTH  = ADDR_WIDTH + 1;

input wire clk;
input wire rst_n;
input wire r_en;

input wire [PTR_WIDTH-1:0] sync_w_ptr;

output wire empty;
output reg  [PTR_WIDTH-1:0] r_ptr;

assign empty = (r_ptr == sync_w_ptr);

always @(posedge clk or negedge rst_n)
begin
    if(!rst_n)
    begin
        r_ptr <= 0;
    end
    else
    begin
        if(!empty && r_en)
        begin
            r_ptr <= r_ptr + 1'b1;
        end
    end
end

endmodule
