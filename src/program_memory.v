module program_memory#(
parameter ADDR_WIDTH = 12,
parameter DATA_WIDTH = 32
)(
input wire clk,
input wire rst_n,

input wire [ADDR_WIDTH-1:0] addr,
output reg [DATA_WIDTH-1:0] wdata
);

localparam DEPTH = 1 << ADDR_WIDTH;
reg [DATA_WIDTH-1:0] mem[0:DEPTH-1];

always@(posedge clk or negedge rst_n)
begin
  if(!rst_n)
    wdata <= 0;
  else
    wdata <= mem[addr];
end
endmodule
