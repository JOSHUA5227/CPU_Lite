module memory_controller#(
parameter ADDR_WIDTH =14,
parameter DATA_WIDTH =32
)(

input wire clk,
input wire rst_n,


// request FIFO ports
input wire [ADDR_WIDTH + DATA_WIDTH :0] req_data,
input wire req_empty,
output wire req_en,

// response FIFO ports
output wire [DATA_WIDTH-1:0] resp_data,
output wire resp_en,
input wire resp_full,

//Data memory ports
output wire [ADDR_WIDTH-1:0] mem_addr,
output wire [DATA_WIDTH-1:0] mem_wdata,

output wire mem_read_en,
output wire mem_write_en,
     
input wire [DATA_WIDTH-1:0] mem_rdata,
input wire mem_rvalid
);

localparam READ_WRITE_BIT = ADDR_WIDTH + DATA_WIDTH;
localparam ADDR_MSB = DATA_WIDTH + ADDR_WIDTH - 1;
localparam ADDR_LSB = DATA_WIDTH;

localparam IDLE = 3'd0;
localparam CAPTURE = 3'd1;
localparam READ_WAIT = 3'd2;
localparam REQUEST = 3'd3;
localparam RESP_WAIT = 3'd4;

reg [2:0] present_state,next_state;

reg reg_read_write;
reg [ADDR_WIDTH-1:0] reg_addr;
reg [DATA_WIDTH-1:0] reg_wdata;

reg [DATA_WIDTH-1:0] reg_resp_data;

assign req_en = (present_state == IDLE) && !req_empty;
assign mem_addr  = reg_addr;
assign mem_wdata = reg_wdata;

assign mem_read_en = (present_state == REQUEST) && (reg_read_write == 1'b0);
assign mem_write_en = (present_state == REQUEST) && (reg_read_write == 1'b1);

assign resp_data = reg_resp_data;
assign resp_en = (present_state == RESP_WAIT) && !resp_full;

always@(posedge clk or negedge rst_n)
begin
  if(!rst_n)
    present_state <= IDLE;
  else
    present_state <= next_state;
end


always@(*)
begin
  case(present_state)
  IDLE: next_state = (!req_empty) ? CAPTURE: IDLE;

  CAPTURE: next_state = REQUEST;

  REQUEST: next_state = (reg_read_write == 1'b0) ? READ_WAIT: IDLE;

  READ_WAIT: next_state = (mem_rvalid) ? RESP_WAIT: READ_WAIT;
  
  RESP_WAIT: next_state = (!resp_full) ? IDLE : RESP_WAIT;

  default: next_state = IDLE;
  endcase
end

always @(posedge clk or negedge rst_n)
begin
  if(!rst_n)
  begin
    reg_read_write <= 1'b0;
    reg_addr <= 0;
    reg_wdata <= 0;
  end
  else
  begin
    if(present_state == CAPTURE)
    begin
      reg_read_write <= req_data[READ_WRITE_BIT];
      reg_addr <= req_data[ADDR_MSB:ADDR_LSB];
      reg_wdata <= req_data[DATA_WIDTH-1:0];
    end
  end
end

always @(posedge clk or negedge rst_n)
begin
  if(!rst_n)
  begin
    reg_resp_data <= 0;
  end
  else
  begin
    if(present_state == READ_WAIT && mem_rvalid)
    begin
      reg_resp_data <= mem_rdata;
    end
  end
end

endmodule


