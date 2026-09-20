module g2b#(parameter WIDTH =4 )(inp,outp);

input wire [WIDTH-1:0] inp;
output reg [WIDTH-1:0] outp;

integer i;
always@(*)
begin
        outp[WIDTH-1] = inp[WIDTH-1];
        for(i =WIDTH-1; i > 0; i= i - 1)
        begin
                outp[i -1] = inp[i-1] ^ outp[i];
        end
end
endmodule
