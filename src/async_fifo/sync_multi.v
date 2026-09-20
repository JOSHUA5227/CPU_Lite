module sync_multi #(parameter WIDTH = 8)(din, dout, clk, rst_n);

input wire clk;
input wire rst_n;
input wire [WIDTH-1:0] din;

output wire [WIDTH-1:0] dout;

reg [WIDTH-1:0] q [0:1];

assign dout = q[1];

always @(posedge clk or negedge rst_n)
begin
    if(!rst_n)
    begin
        q[0] <= 0;
        q[1] <= 0;
    end
    else
    begin
        q[0] <= din;
        q[1] <= q[0];
    end
end

endmodule
