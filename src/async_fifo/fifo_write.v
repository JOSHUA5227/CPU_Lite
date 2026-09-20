module fifo_write #(parameter DEPTH = 8)(
    clk,
    rst_n,
    w_en,
    full,
    w_ptr,
    sync_r_ptr
);

localparam ADDR_WIDTH = $clog2(DEPTH);
localparam PTR_WIDTH  = ADDR_WIDTH + 1;

input wire clk;
input wire rst_n;
input wire w_en;

input wire [PTR_WIDTH-1:0] sync_r_ptr;

output wire full;
output reg  [PTR_WIDTH-1:0] w_ptr;

assign full = (w_ptr == {~sync_r_ptr[PTR_WIDTH-1],
                         sync_r_ptr[PTR_WIDTH-2:0]});

always @(posedge clk or negedge rst_n)
begin
    if(!rst_n)
    begin
        w_ptr <= 0;
    end
    else
    begin
        if(!full && w_en)
        begin
            w_ptr <= w_ptr + 1'b1;
        end
    end
end

endmodule
