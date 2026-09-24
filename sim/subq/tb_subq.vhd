-- Testbench for the real Subchannel Q path of cd_top (subqExt mode)
--
-- Disc model: one data track, Q generated per frame like a real pressed disc
-- (track 01, index 01, relative MSF = frame - 150), with some special frames:
--    14105, 14110 : LibCrypt style, modified MSF + bad CRC      -> GetLocP must keep the previous position
--    14112        : ADR=2 (catalog) frame                        -> ignored like on the real controller
--    14115        : index 02                                     -> must be visible (proves passthrough)
--    14118        : HPS has no Q                                 -> core must synthesize it
-- The synthesized Q of the core uses relative MSF = frame (no 2s offset), so real vs synthesized
-- can be told apart by the relative MSF returned from GetLocP.
--
-- Run: see run_tb_subq.sh

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

library psx;

entity tb_subq is
end entity;

architecture arch of tb_subq is

   signal clk1x            : std_logic := '1';
   signal reset            : std_logic := '1';
   signal SS_reset         : std_logic := '1';
   signal SS_wren          : std_logic := '0';
   signal SS_Adr           : unsigned(13 downto 0) := (others => '0');
   signal SS_DataWrite     : std_logic_vector(31 downto 0) := (others => '0');

   signal bus_addr         : unsigned(3 downto 0) := (others => '0');
   signal bus_dataWrite    : std_logic_vector(7 downto 0) := (others => '0');
   signal bus_read         : std_logic := '0';
   signal bus_write        : std_logic := '0';
   signal bus_dataRead     : std_logic_vector(7 downto 0);

   signal cd_hps_req       : std_logic;
   signal cd_hps_lba       : std_logic_vector(31 downto 0);
   signal cd_hps_ack       : std_logic := '0';
   signal cd_hps_write     : std_logic := '0';
   signal cd_hps_data      : std_logic_vector(15 downto 0) := (others => '0');

   signal trackinfo_data   : std_logic_vector(31 downto 0) := (others => '0');
   signal trackinfo_addr   : std_logic_vector(8 downto 0) := (others => '0');
   signal trackinfo_write  : std_logic := '0';

   signal subq_set          : std_logic := '0';
   signal subq_set_tag      : std_logic_vector(23 downto 0) := (others => '0');
   signal subq_set_status   : std_logic_vector(7 downto 0) := (others => '0');
   signal subq_set_data     : std_logic_vector(95 downto 0) := (others => '0');
   signal subq_req_phys_seq : std_logic_vector(7 downto 0);
   signal subq_req_phys_tag : std_logic_vector(23 downto 0);
   signal subq_req_getq_seq : std_logic_vector(7 downto 0);
   signal subq_req_getq     : std_logic_vector(15 downto 0);

   signal spu_tick         : std_logic := '0';
   signal fastCD           : std_logic := '1';

   signal physReqCount     : integer := 0;
   signal testDone         : boolean := false;

   function bcd(v : integer) return std_logic_vector is
   begin
      return std_logic_vector(to_unsigned((v / 10) * 16 + (v mod 10), 8));
   end function;

   function unbcd(v : std_logic_vector(7 downto 0)) return integer is
   begin
      return to_integer(unsigned(v(7 downto 4))) * 10 + to_integer(unsigned(v(3 downto 0)));
   end function;

   -- Q of a frame on the modeled disc: returns status(7..0) & data(95..0)
   function disc_q(frame : integer) return std_logic_vector is
      variable q   : std_logic_vector(95 downto 0);
      variable st  : std_logic_vector(7 downto 0) := x"03"; -- present, crc ok
      variable rel : integer;
      variable f   : integer := frame;
   begin
      rel := frame - 150;
      if (rel < 0) then rel := 0; end if;
      if (frame = 14105 or frame = 14110) then f := frame + 1024; st := x"01"; end if; -- LibCrypt: MSF bits changed, CRC bad
      q(7 downto 0)   := x"41";                -- control data track, ADR 1
      q(15 downto 8)  := x"01";                -- track
      q(23 downto 16) := x"01";                -- index
      if (frame = 14115) then q(23 downto 16) := x"02"; end if;
      q(31 downto 24) := bcd(rel / 4500);
      q(39 downto 32) := bcd((rel / 75) mod 60);
      q(47 downto 40) := bcd(rel mod 75);
      q(55 downto 48) := x"00";
      q(63 downto 56) := bcd(f / 4500);
      q(71 downto 64) := bcd((f / 75) mod 60);
      q(79 downto 72) := bcd(f mod 75);
      q(95 downto 80) := x"0000";              -- CRC not checked by the core (status bit 1 carries it)
      if (frame = 14112) then q(7 downto 0) := x"42"; q(79 downto 8) := x"341234123412341234"; end if; -- ADR 2 catalog
      if (frame = 14118) then st := x"00"; end if;                                                         -- no Q available
      return st & q;
   end function;

   procedure tick(signal clk : in std_logic; n : integer) is
   begin
      for i in 1 to n loop
         wait until rising_edge(clk);
      end loop;
   end procedure;

begin

   clk1x <= not clk1x after 15 ns;

   icd_top : entity psx.cd_top
   generic map
   (
      GETQ_SEARCH_TIME => 20000,
      GETQ_TIMEOUT     => 400000
   )
   port map
   (
      clk1x                => clk1x,
      ce                   => '1',
      reset                => reset,
      INSTANTSEEK          => '0',
      FORCECDSPEED         => "000",
      LIMITREADSPEED       => '0',
      hasCD                => '1',
      LIDopen              => '0',
      fastCD               => fastCD,
      testSeek             => '0',
      pauseOnCDSlow        => '0',
      region               => "00",
      region_out           => open,
      pauseCD              => open,
      Pause_idle_cd        => open,
      fullyIdle            => open,
      cdSlow               => open,
      error                => open,
      LBAdisplay           => open,
      irqOut               => open,
      spu_tick             => spu_tick,
      cd_left              => open,
      cd_right             => open,
      mdec_idle            => '1',
      bus_addr             => bus_addr,
      bus_dataWrite        => bus_dataWrite,
      bus_read             => bus_read,
      bus_write            => bus_write,
      bus_dataRead         => bus_dataRead,
      dma_read             => '0',
      dma_readdata         => open,
      cd_hps_req           => cd_hps_req,
      cd_hps_lba           => cd_hps_lba,
      cd_hps_lba_sim       => open,
      cd_hps_ack           => cd_hps_ack,
      cd_hps_write         => cd_hps_write,
      cd_hps_data          => cd_hps_data,
      trackinfo_data       => trackinfo_data,
      trackinfo_addr       => trackinfo_addr,
      trackinfo_write      => trackinfo_write,
      resetFromCD          => open,
      subq_set             => subq_set,
      subq_set_tag         => subq_set_tag,
      subq_set_status      => subq_set_status,
      subq_set_data        => subq_set_data,
      subq_req_phys_seq    => subq_req_phys_seq,
      subq_req_phys_tag    => subq_req_phys_tag,
      subq_req_getq_seq    => subq_req_getq_seq,
      subq_req_getq        => subq_req_getq,
      SS_reset             => SS_reset,
      SS_DataWrite         => SS_DataWrite,
      SS_Adr               => SS_Adr,
      SS_wren              => SS_wren,
      SS_rden              => '0',
      SS_DataRead          => open,
      SS_idle              => open
   );

   -- 44.1 kHz tick
   process
      variable cnt : integer := 0;
   begin
      wait until rising_edge(clk1x);
      spu_tick <= '0';
      if (cnt < 767) then cnt := cnt + 1; else cnt := 0; spu_tick <= '1'; end if;
   end process;

   -- HPS model: sector data + CD_SET per sector, answers physical-position and GetQ requests
   process
      variable lba       : integer;
      variable sq        : std_logic_vector(103 downto 0);
      variable w         : std_logic_vector(15 downto 0);
      variable b0, b1    : integer;
      variable physSeq   : std_logic_vector(7 downto 0) := x"00";
      variable getqSeq   : std_logic_vector(7 downto 0) := x"00";
      variable tag       : integer;
   begin
      wait until rising_edge(clk1x);

      if (reset = '0' and cd_hps_req = '1') then
         lba := to_integer(unsigned(cd_hps_lba(23 downto 0)));
         tick(clk1x, 50);
         -- CD_SET for frame lba+2 (the core shows Q two frames ahead of the data)
         sq := disc_q(lba + 2);
         subq_set_tag    <= std_logic_vector(to_unsigned(lba + 2, 24));
         subq_set_status <= sq(103 downto 96);
         subq_set_data   <= sq(95 downto 0);
         subq_set        <= '1';
         wait until rising_edge(clk1x);
         subq_set        <= '0';
         tick(clk1x, 20);
         cd_hps_ack <= '1';
         wait until rising_edge(clk1x);
         cd_hps_ack <= '0';
         wait until rising_edge(clk1x);
         for i in 0 to 1175 loop
            -- byte 2i and 2i+1 of a Mode 2 sector with correct header
            w := (others => '0');
            for k in 0 to 1 loop
               b0 := 2 * i + k;
               if (b0 = 0 or b0 = 11) then b1 := 0;
               elsif (b0 < 11) then b1 := 255;
               elsif (b0 = 12) then b1 := to_integer(unsigned(bcd(lba / 4500)));
               elsif (b0 = 13) then b1 := to_integer(unsigned(bcd((lba / 75) mod 60)));
               elsif (b0 = 14) then b1 := to_integer(unsigned(bcd(lba mod 75)));
               elsif (b0 = 15) then b1 := 2;
               else b1 := (b0 + lba) mod 256;
               end if;
               w(k * 8 + 7 downto k * 8) := std_logic_vector(to_unsigned(b1, 8));
            end loop;
            cd_hps_data  <= w;
            cd_hps_write <= '1';
            wait until rising_edge(clk1x);
            cd_hps_write <= '0';
            wait until rising_edge(clk1x);
         end loop;

      elsif (reset = '0' and subq_req_phys_seq /= physSeq) then
         physSeq := subq_req_phys_seq;
         tag     := to_integer(unsigned(subq_req_phys_tag));
         physReqCount <= physReqCount + 1;
         tick(clk1x, 300); -- HPS latency (psx_poll)
         sq := disc_q(tag);
         subq_set_tag    <= subq_req_phys_tag;
         subq_set_status <= sq(103 downto 96);
         subq_set_data   <= sq(95 downto 0);
         subq_set        <= '1';
         wait until rising_edge(clk1x);
         subq_set        <= '0';

      elsif (reset = '0' and subq_req_getq_seq /= getqSeq) then
         getqSeq := subq_req_getq_seq;
         tick(clk1x, 1000);
         subq_set_tag <= x"00" & subq_req_getq;
         if (subq_req_getq = x"01A2") then -- lead-out pointer: A2 at 58:12:34 (example values)
            subq_set_status <= x"07";       -- present, crc ok, lead-in reply
            subq_set_data   <= x"0000" & x"34" & x"12" & x"58" & x"00" & x"07" & x"05" & x"99" & x"A2" & x"00" & x"41";
         else
            subq_set_status <= x"0C";       -- lead-in reply, not found
            subq_set_data   <= (others => '0');
         end if;
         subq_set <= '1';
         wait until rising_edge(clk1x);
         subq_set <= '0';
      end if;
   end process;

   -- CPU / BIOS model
   process
      type tbytes is array(0 to 15) of std_logic_vector(7 downto 0);
      variable resp       : tbytes;
      variable respCount  : integer;
      variable flags      : std_logic_vector(7 downto 0);
      variable errors     : integer := 0;
      variable absFrame   : integer;
      variable relFrame   : integer;
      variable lastAbs    : integer;
      variable seen14104, seen14105, seen14110, seen14112, seenIdx2, seen14118synth : integer := 0;
      variable physReal, physSynth : integer := 0;
      variable realAfterMiss : integer := 0;

      procedure wr(a : integer; d : std_logic_vector(7 downto 0)) is
      begin
         bus_addr <= to_unsigned(a, 4); bus_dataWrite <= d; bus_write <= '1';
         wait until rising_edge(clk1x);
         bus_write <= '0';
         wait until rising_edge(clk1x);
      end procedure;

      procedure rd(a : integer; d : out std_logic_vector(7 downto 0)) is
      begin
         bus_addr <= to_unsigned(a, 4); bus_read <= '1';
         wait until rising_edge(clk1x);
         bus_read <= '0';
         wait until rising_edge(clk1x);
         d := bus_dataRead;
      end procedure;

      -- wait for a specific INTn, reading and acknowledging (and discarding) any other IRQ on the way
      procedure wait_int(expected : integer; timeout : integer; ok : out boolean) is
         variable st : std_logic_vector(7 downto 0);
         variable n  : integer := 0;
      begin
         ok := false;
         respCount := 0;
         while n < timeout loop
            wr(0, x"01");
            rd(3, flags);
            if (flags(2 downto 0) /= "000") then
               wr(0, x"00");
               respCount := 0;
               loop
                  rd(0, st);
                  exit when st(5) = '0';
                  rd(1, resp(respCount));
                  respCount := respCount + 1;
                  tick(clk1x, 2); -- status register (RSLRRDY) follows the FIFO one cycle later
                  exit when respCount = 16;
               end loop;
               wr(0, x"01");
               wr(3, x"1F"); -- ack
               if (to_integer(unsigned(flags(2 downto 0))) = expected) then
                  ok := true;
                  return;
               end if;
               if (to_integer(unsigned(flags(2 downto 0))) = 5) then
                  report "unexpected INT5, bytes " & integer'image(respCount) & " err " & integer'image(to_integer(unsigned(resp(0)))) severity warning;
               end if;
            end if;
            tick(clk1x, 200);
            n := n + 200;
         end loop;
      end procedure;

      procedure command(cmd : std_logic_vector(7 downto 0); p0, p1, p2 : integer; np : integer) is
      begin
         wr(0, x"00");
         if (np > 0) then wr(2, std_logic_vector(to_unsigned(p0, 8))); end if;
         if (np > 1) then wr(2, std_logic_vector(to_unsigned(p1, 8))); end if;
         if (np > 2) then wr(2, std_logic_vector(to_unsigned(p2, 8))); end if;
         wr(1, cmd);
      end procedure;

      procedure check(cond : boolean; msg : string) is
      begin
         if (cond) then
            report "ok   " & msg;
         else
            report "FAIL " & msg severity error;
            errors := errors + 1;
         end if;
      end procedure;

      procedure getlocp(ok : out boolean) is
      begin
         command(x"11", 0, 0, 0, 0);
         wait_int(3, 2000000, ok);
         if (ok and respCount >= 8) then
            if (respCount /= 8) then report "GetLocP response bytes: " & integer'image(respCount); end if;
            absFrame := (unbcd(resp(5)) * 60 + unbcd(resp(6))) * 75 + unbcd(resp(7));
            relFrame := (unbcd(resp(2)) * 60 + unbcd(resp(3))) * 75 + unbcd(resp(4));
         else
            absFrame := -1; relFrame := -1;
         end if;
      end procedure;

      variable ok : boolean;
   begin
      -- reset with savestate defaults, but start with motor on, shell closed, double speed
      -- (skips the ~1s lid-close/spin-up sequence, the disc change detection needs ~2s so it never fires here)
      tick(clk1x, 10);
      reset <= '1'; SS_reset <= '1';
      tick(clk1x, 10);
      SS_reset <= '0';
      tick(clk1x, 10);
      SS_Adr <= to_unsigned(13, 14); SS_DataWrite <= x"00008002"; SS_wren <= '1';
      wait until rising_edge(clk1x);
      SS_wren <= '0';
      tick(clk1x, 100);
      reset <= '0';
      tick(clk1x, 100);

      -- disk_t: 1 data track, subqExt set (bit 19 of word 3)
      for i in 0 to 7 loop
         case i is
            when 0 => trackinfo_data <= x"00000101";
            when 1 => trackinfo_data <= std_logic_vector(to_unsigned(200000, 32));
            when 2 => trackinfo_data <= x"00002C24"; -- 44:26
            when 3 => trackinfo_data <= x"000A0000"; -- region US, subqExt
            when 4 => trackinfo_data <= x"00000000"; -- track 1 start
            when 5 => trackinfo_data <= std_logic_vector(to_unsigned(200000, 32));
            when 6 => trackinfo_data <= x"00000002"; -- 00:02, data
            when others => trackinfo_data <= x"00000000";
         end case;
         trackinfo_addr  <= std_logic_vector(to_unsigned(i, 9));
         trackinfo_write <= '1';
         wait until rising_edge(clk1x);
         -- reset right after each write cancels the disc change sequence (lid open, ~2s wait, spin-up),
         -- which would take far too long to simulate. TOC, libcrypt/subqExt and track RAM stay written.
         trackinfo_write <= '0';
         reset           <= '1';
         tick(clk1x, 3);
         reset           <= '0';
         tick(clk1x, 4);
      end loop;
      tick(clk1x, 100);

      -- irq enable
      wr(0, x"01");
      wr(2, x"1F");

      fastCD <= '0';
      command(x"01", 0, 0, 0, 0); -- GetStat
      wait_int(3, 2000000, ok);
      check(ok and resp(0)(1) = '1', "drive ready, stat=" & integer'image(to_integer(unsigned(resp(0)))));

      -------------------------------------------------------------------
      report "=== GetQ ===";
      wr(0, x"00");
      wr(2, x"01");
      wr(2, x"A2");
      wr(1, x"1D");
      wait_int(3, 2000000, ok);
      check(ok, "GetQ INT3");
      wait_int(2, 4000000, ok);
      check(ok and respCount = 11, "GetQ INT2 with 11 bytes (got " & integer'image(respCount) & ")");
      check(resp(0) = x"41" and resp(2) = x"A2" and resp(7) = x"58" and resp(8) = x"12" and resp(9) = x"34" and resp(10) = x"00",
            "GetQ lead-in data A2 -> 58:12:34");
      command(x"1D", 16#01#, 16#55#, 0, 2);
      wait_int(3, 2000000, ok);
      check(ok, "GetQ (missing point) INT3");
      wait_int(5, 4000000, ok);
      check(ok, "GetQ (missing point) INT5 after timeout");

      -------------------------------------------------------------------
      report "=== sector path: ReadN from 03:08:00 + GetLocP after each INT1 ===";
      command(x"02", 16#03#, 16#08#, 16#00#, 3);
      wait_int(3, 2000000, ok);
      check(ok, "Setloc");
      command(x"06", 0, 0, 0, 0);
      wait_int(3, 2000000, ok);
      check(ok, "ReadN INT3");
      lastAbs := 0;
      for n in 0 to 21 loop
         wait_int(1, 8000000, ok);
         exit when not ok;
         getlocp(ok);
         report "GetLocP after INT1: abs " & integer'image(absFrame) & " rel " & integer'image(relFrame) &
                " track " & integer'image(unbcd(resp(0))) & " index " & integer'image(unbcd(resp(1)));
         if (absFrame = 14104) then seen14104 := seen14104 + 1; end if;
         if (absFrame = 14105) then seen14105 := seen14105 + 1; end if;
         if (absFrame = 14110) then seen14110 := seen14110 + 1; end if;
         if (absFrame = 14112) then seen14112 := seen14112 + 1; end if;
         if (absFrame = 14115 and resp(1) = x"02" and relFrame = 14115 - 150) then seenIdx2 := seenIdx2 + 1; end if;
         if (absFrame = 14118 and relFrame = 14118) then seen14118synth := seen14118synth + 1; end if;
         if (absFrame < lastAbs) then check(false, "position went backwards"); end if;
         lastAbs := absFrame;
      end loop;
      check(seen14105 = 0 and seen14110 = 0, "LibCrypt frames (bad CRC) never reported");
      check(seen14104 >= 2, "previous position kept on bad-CRC frame (14104 reported twice)");
      check(seen14112 = 0, "ADR=2 frame ignored");
      check(seenIdx2 = 1, "real Q passed through (frame 14115 index 02, real relative MSF)");
      check(seen14118synth = 1, "missing Q synthesized by the core (frame 14118)");

      command(x"09", 0, 0, 0, 0); -- Pause
      wait_int(3, 8000000, ok);
      wait_int(2, 40000000, ok);
      check(ok, "Pause INT2");

      -------------------------------------------------------------------
      report "=== physical position path while paused (recently read area -> Q cache) ===";
      for n in 0 to 23 loop
         getlocp(ok);
         if (relFrame = absFrame - 150) then physReal := physReal + 1; elsif (relFrame = absFrame and absFrame /= 14118) then physSynth := physSynth + 1; end if;
         report "GetLocP paused: abs " & integer'image(absFrame) & " rel " & integer'image(relFrame);
         tick(clk1x, 30000);
      end loop;
      check(physReal > 0 and physSynth = 0, "paused GetLocP served from real Q cache, only 14118 (no Q on disc) synthesized (real " & integer'image(physReal) & ", synth " & integer'image(physSynth) & ")");

      -------------------------------------------------------------------
      -------------------------------------------------------------------
      report "=== physical position in an area never read: synthesized first, real after HPS answers ===";
      command(x"02", 16#04#, 16#30#, 16#00#, 3);
      wait_int(3, 2000000, ok);
      command(x"15", 0, 0, 0, 0); -- SeekL
      wait_int(3, 2000000, ok);
      wait_int(2, 40000000, ok);
      check(ok, "SeekL done");
      physReal := 0; physSynth := 0;
      for n in 0 to 59 loop
         getlocp(ok);
         if (relFrame = absFrame - 150) then physReal := physReal + 1; elsif (relFrame = absFrame) then physSynth := physSynth + 1; end if;
         if (n >= 30 and relFrame = absFrame - 150) then realAfterMiss := realAfterMiss + 1; end if;
         tick(clk1x, 30000);
      end loop;
      report "phys requests to HPS: " & integer'image(physReqCount) & ", real " & integer'image(physReal) & ", synth " & integer'image(physSynth);
      check(physReqCount > 0, "core requested missing Q from HPS");
      check(realAfterMiss = 30, "after HPS answered, GetLocP returns real Q (" & integer'image(realAfterMiss) & "/30)");

      if (errors = 0) then
         report "ALL TESTS PASSED";
      else
         report integer'image(errors) & " TESTS FAILED" severity error;
      end if;
      testDone <= true;
      std.env.stop;
      wait;
   end process;

end architecture;
