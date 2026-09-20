module b2g#(parameter WIDTH = 4)(inp,outp);
input wire [WIDTH-1:0] inp;
output wire [WIDTH-1:0] outp;


assign outp = inp ^ (inp >> 1);
endmodule
