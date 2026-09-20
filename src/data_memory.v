module data_memory#(
parameter ADDR_WIDTH = 14,
parameter DATA_WIDTH = 32
)(
input wire clk,
input wire rst_n,

input wire read_en,
input wire write_en,

input wire [ADDR_WIDTH-1:0] addr,
input wire [DATA_WIDTH-1:0] wdata,

output reg [DATA_WIDTH-1:0] rdata,
output reg rvalid
);

localparam DEPTH = 1 << ADDR_WIDTH;

reg [DATA_WIDTH-1:0] mem[0:DEPTH-1];


always@(posedge clk or negedge rst_n)
begin
  if(!rst_n)
  begin
      rdata <=0;
      rvalid <=0;
  end
  else
  begin
     rvalid <=0;
    
     if(write_en)
        mem[addr] <= wdata;

     if(read_en)
     begin
        rdata <= mem[addr];
        rvalid <= 1;
     end
  end
end
endmodule
