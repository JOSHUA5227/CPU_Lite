module mem #(parameter WIDTH = 4, DEPTH = 8)(
    w_clk,
    r_clk,
    w_en,
    w_data,
    r_data,
    w_addr,
    r_addr
);

localparam ADDR_WIDTH = $clog2(DEPTH);

input wire w_clk;
input wire r_clk;

input wire w_en;

input wire [WIDTH-1:0] w_data;
input wire [ADDR_WIDTH-1:0] w_addr;
input wire [ADDR_WIDTH-1:0] r_addr;

output reg [WIDTH-1:0] r_data;

reg [WIDTH-1:0] mem [0:DEPTH-1];

always @(posedge w_clk)
begin
    if(w_en)
    begin
        mem[w_addr] <= w_data;
    end
end

always @(posedge r_clk)
begin
     r_data <= mem[r_addr];
end

endmodule
