module cache#(
parameter ADDR_WIDTH = 14,
parameter DATA_WIDTH = 32,
parameter CACHE_LINES = 8,
parameter WORDS_PER = 4 )(

input wire clk,
input wire rst_n,


// CPU side ports 
input wire cpu_req,
input wire read_write,
input wire [ADDR_WIDTH-1:0] addr,
input wire [DATA_WIDTH-1:0] wdata,

output reg [DATA_WIDTH-1:0] rdata,
output reg cpu_ready,

//request FIFO side ports
input wire fifo_req_full,
output reg [ADDR_WIDTH+DATA_WIDTH:0] fifo_req_data, //address + data + read or write
output reg fifo_req_en,

//response FIFO side ports
output reg fifo_resp_en,
input wire [DATA_WIDTH-1:0] fifo_resp_data,
input wire fifo_resp_empty
);

localparam COUNT_BITS = $clog2(WORDS_PER + 1);
localparam OFFSET_BITS = $clog2(WORDS_PER);
localparam INDEX_BITS = $clog2(CACHE_LINES);
localparam TAG_BITS = ADDR_WIDTH - OFFSET_BITS - INDEX_BITS;

reg [ADDR_WIDTH-1:0] writeback_base;
reg [ADDR_WIDTH-1:0] refill_base;
reg [ADDR_WIDTH-1:0] reg_addr;
reg [DATA_WIDTH-1:0] reg_wdata;
reg reg_read_write;

reg dirty_bit_array [0:CACHE_LINES-1];
reg valid_array [0:CACHE_LINES-1];
reg [TAG_BITS-1:0] tag_array [0:CACHE_LINES-1];
reg [DATA_WIDTH-1:0] data_array [0:CACHE_LINES-1][0:WORDS_PER-1]; 

reg [COUNT_BITS-1:0] writeback_req_count;
reg [COUNT_BITS-1:0] refill_req_count;
reg [COUNT_BITS-1:0] refill_resp_count;

reg resp_pending;

wire [TAG_BITS-1:0] addr_tag;
wire [INDEX_BITS-1:0] addr_index;
wire [OFFSET_BITS-1:0] addr_offset;

assign addr_tag = reg_addr[ADDR_WIDTH-1:ADDR_WIDTH-TAG_BITS];
assign addr_index = reg_addr[OFFSET_BITS+INDEX_BITS-1:OFFSET_BITS];
assign addr_offset = reg_addr[OFFSET_BITS-1:0];

wire cache_hit;
assign cache_hit = valid_array[addr_index] && (tag_array[addr_index] == addr_tag);

wire [OFFSET_BITS-1:0] refill_resp_index;
assign refill_resp_index = refill_resp_count[OFFSET_BITS-1:0];

localparam IDLE = 3'd0;
localparam LOOKUP = 3'd1;
localparam FIFO_WAIT = 3'd2;
localparam WRITEBACK = 3'd3;
localparam REFILL_WAIT = 3'd4;
localparam RESPONSE = 3'd5;


reg [2:0] present_state,next_state;


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
    IDLE: next_state = (cpu_req) ? LOOKUP : IDLE;
    LOOKUP:
    begin
             if(cache_hit)
             begin
             //   if(reg_read_write)
             //   next_state = (!fifo_req_full) ? RESPONSE : FIFO_WAIT;
             //   else implementing writeback
                 next_state = RESPONSE;
             end
             else
             begin
                if(reg_read_write)
                 next_state = (!fifo_req_full) ? RESPONSE : FIFO_WAIT;
                else
                begin
                 if(dirty_bit_array[addr_index] == 1)
                    next_state = WRITEBACK;
                 else
                    next_state = REFILL_WAIT;
                end
             end 
    end
    FIFO_WAIT: next_state = (fifo_req_full) ? FIFO_WAIT : RESPONSE;
    
    WRITEBACK: next_state = (writeback_req_count == WORDS_PER)? REFILL_WAIT : WRITEBACK;

    REFILL_WAIT: next_state = ( (refill_req_count == WORDS_PER) && (refill_resp_count == WORDS_PER) ) ? RESPONSE : REFILL_WAIT;

    RESPONSE: next_state = IDLE;

   default: next_state = IDLE;
   endcase
end


always@(*)
begin
    rdata = 0;
    cpu_ready =0;

    fifo_req_data = 0;
    fifo_req_en = 0;

    fifo_resp_en =0;

    case(present_state)
    WRITEBACK:
    begin
      if(!fifo_req_full && writeback_req_count < WORDS_PER )
      begin
        fifo_req_data = {1'b1,writeback_base+writeback_req_count,data_array[addr_index][writeback_req_count]};
        fifo_req_en = 1;
      end
    end

    REFILL_WAIT:
    begin
      if(!fifo_req_full && refill_req_count < WORDS_PER )
      begin
        fifo_req_data = {1'b0,refill_base+refill_req_count,{DATA_WIDTH{1'b0}}};
        fifo_req_en = 1;
      end

      if(!fifo_resp_empty && refill_resp_count <WORDS_PER && !resp_pending) 
         fifo_resp_en = 1;
    end
    
    RESPONSE:
    begin
      cpu_ready = 1;
      
      if(reg_read_write)
      begin
        if(!cache_hit && !fifo_req_full)
        begin
          fifo_req_data = {1'b1,reg_addr,reg_wdata}; 
          fifo_req_en = 1;
        end
      end
      else
        rdata = data_array[addr_index][addr_offset];
    end

    default:
    begin
    rdata = 0;
    cpu_ready =0;

    fifo_req_data = 0;
    fifo_req_en = 0;

    fifo_resp_en =0;
    end
    endcase
end


always@(posedge clk or negedge rst_n)
begin
  if(!rst_n)
  begin
    reg_addr <= 0;
    reg_wdata <=0;
    reg_read_write <= 0;
    refill_base <= 0;
    writeback_base <= 0;
  end
  else
  begin
    if(present_state ==IDLE && cpu_req)
    begin
      reg_addr <=addr;
      reg_wdata <= wdata;
      reg_read_write <= read_write;
      refill_base <= {addr[ADDR_WIDTH-1:OFFSET_BITS],{OFFSET_BITS{1'b0}} };
    end
    else if(present_state == LOOKUP && !cache_hit && !reg_read_write && dirty_bit_array[addr_index])
    begin
        writeback_base <= {tag_array[addr_index],addr_index,{OFFSET_BITS{1'b0}} };
    end
  end
end

always@(posedge clk or negedge rst_n)
begin
  if(!rst_n)
  begin
    writeback_req_count <= 0;
    refill_req_count <= 0;
    refill_resp_count <= 0;
  end
  else
  begin
      if(present_state == WRITEBACK)
      begin
         if(!fifo_req_full && writeback_req_count < WORDS_PER)
              writeback_req_count <= writeback_req_count + 1;
      end
      else if(present_state == REFILL_WAIT)
      begin
          if(!fifo_req_full && refill_req_count < WORDS_PER)
            refill_req_count <= refill_req_count + 1;

          
          if(resp_pending && refill_resp_count < WORDS_PER)
            refill_resp_count <= refill_resp_count + 1;
      end
      else if(present_state == IDLE)
      begin
          writeback_req_count <= 0;
          refill_req_count <= 0;
          refill_resp_count <= 0;
      end
  end
end


integer i;
always@(posedge clk or negedge rst_n)
begin
  if(!rst_n)
  begin
      for(i =0; i < CACHE_LINES; i = i+1)
      begin
          valid_array[i] <= 0;
          dirty_bit_array[i] <= 0;
      end
  end
  else
  begin
    case(present_state)
    LOOKUP:
    begin
      if(cache_hit && reg_read_write)
           data_array[addr_index][addr_offset] <= reg_wdata;
    end
    WRITEBACK:
    begin
      if(!fifo_req_full && (writeback_req_count == WORDS_PER-1))
          dirty_bit_array[addr_index] <= 0;
    end
    REFILL_WAIT:
    begin
      if(resp_pending && refill_resp_count < WORDS_PER)
      begin
          data_array[addr_index][refill_resp_index] <= fifo_resp_data;
          if(refill_resp_count == WORDS_PER-1)
          begin
              valid_array[addr_index] <= 1'b1;
              tag_array[addr_index]   <= addr_tag;
          end
      end
    end
    RESPONSE:
    begin
       if(reg_read_write)
       begin
          dirty_bit_array[addr_index] <= 1'b1;
          data_array[addr_index][addr_offset] <= reg_wdata;
       end
    end
    endcase
    /*
      if(present_state == LOOKUP && cache_hit && reg_read_write)
        data_array[addr_index][addr_offset] <= reg_wdata;

      else if(present_state == REFILL_WAIT && resp_pending && refill_resp_count < WORDS_PER)
        data_array[addr_index][refill_resp_index] <= fifo_resp_data;

      if((present_state == REFILL_WAIT) && resp_pending && (refill_resp_count == WORDS_PER-1))
        begin
            valid_array[addr_index] <= 1'b1;
            tag_array[addr_index]   <= addr_tag;
        end
      */
  end
end

always@(posedge clk or negedge rst_n)
begin
    if(!rst_n)
        resp_pending <= 1'b0;
    else if(present_state == IDLE)
        resp_pending <= 1'b0;
    else if(present_state == REFILL_WAIT)
    begin
        if(fifo_resp_en)
            resp_pending <= 1'b1;
        else if(resp_pending)
            resp_pending <= 1'b0;
    end
end
endmodule
