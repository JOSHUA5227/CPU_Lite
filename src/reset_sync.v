module reset_sync(
input wire clk,
input wire rst_n,

output wire new_reset
);

reg q1,q0;

always@(posedge clk or negedge rst_n)
begin
  if(!rst_n)
  begin
      {q1,q0} <= 0;
  end
  else
      {q1,q0} <= {q0,1'b1};
end

assign new_reset = q1;
endmodule
