(*****************************************************************************

  Liquidsoap, a programmable audio stream generator.
  Copyright 2003-2009 Savonet team

  This program is free software; you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation; either version 2 of the License, or
  (at your option) any later version.

  This program is distributed in the hope that it will be useful,
  but WITHOUT ANY WARRANTY; without even the implied warranty of
  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
  GNU General Public License for more details, fully stated in the COPYING
  file at the root of the liquidsoap distribution.

  You should have received a copy of the GNU General Public License
  along with this program; if not, write to the Free Software
  Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA

 *****************************************************************************)

open Dtools
open Source

let conf =
  Conf.void ~p:(Configure.conf#plug "root") "Streaming root node settings"
let conf_max_latency =
  Conf.float ~p:(conf#plug "max_latency") ~d:60. "Maximum latency in seconds"
    ~comments:[
      "If the latency gets higher than this value, the outputs will be reset,";
      "instead of trying to catch it up second by second." ;
      "The reset is typically only useful to reconnect icecast mounts."
    ]
let conf_sync =
  Conf.bool ~p:(conf#plug "sync") ~d:true "Synchronization flag"
    ~comments:[
      "Control whether or not liquidsoap should take care of the timing.";
      "Otherwise, the sources may handle it by themselves -- typically in the ";
      "case of un-bufferized alsa I/O, which turns root synchronization off";
      "automatically.";
      "Leaving the sources without synchronization can also be useful for ";
      "debugging or measuring performance, as it results in liquidsoap running";
      "as fast as possible."
    ]

let log = Log.make ["root"]

let uptime =
  let base = Unix.time () in
    fun () ->
      (Unix.time ()) -. base

let shutdown = ref false

(** Timing stuff, make sure the frame rate is correct. *)

let time = Unix.gettimeofday
let usleep d =
  (* In some implementations,
   * Thread.delay uses Unix.select which can raise EINTR.
   * A really good implementation would keep track of the elapsed time and then
   * trigger another Thread.delay for the remaining time.
   * This cheap thing does the job for now.. *)
  try Thread.delay d with Unix.Unix_error (Unix.EINTR,_,_) -> ()
let t0 = ref 0.
let ticks = ref 0L
let delay () =
  !t0
  +. (Lazy.force Frame.duration) *. Int64.to_float (Int64.add !ticks 1L)
  -. time ()

(** Main loop. *)

let started = ref false
let running () = !started

let sleep () =
  if !started then begin
    log#f 3 "Shutting down sources..." ;
    Source.iter_outputs (fun s -> s#leave (s:>Source.source))
  end

let start () =

  let acc = ref 0 in
  let max_latency = -. conf_max_latency#get in
  let sync = conf_sync#get in
  let last_latency_log = ref (time ()) in

  log#f 3 "Waking up active nodes..." ;
  (* Wake up outputs:
   * Once this is done, the [started] flag is set, that tells Main to
   * clean up those sources before shutting down if we crash.
   * But we have to handle the case of a crash during the waking_up phase,
   * by releasing cleanly the sources that have been woken up successfully. *)
  ignore
    (Source.fold_outputs
       (fun awoken s ->
          try
            s#get_ready [(s:>Source.source)] ;
            s::awoken
          with
            | e ->
                log#f 2 "Error during the awakening phase, rolling back..." ;
                List.iter
                  (fun (s:active_source) ->
                     try s#leave (s:>Source.source) with
                       | e ->
                           log#f 2 "Leaving source %s failed: %s!"
                             s#id (Printexc.to_string e))
                  awoken ;
                raise e)
       []) ;
  started := true ;
  Source.iter_outputs (fun s -> s#output_get_ready) ;

  log#f 3 "Broadcast starts up!" ;
  t0 := time () ;
  while not !shutdown do
    let rem = if not sync then 0. else delay () in
      (* Sleep a while or worry about the latency *)
      if (not sync) || rem > 0. then begin
        acc := 0 ;
        usleep rem
      end else begin
        incr acc ;
        if rem < max_latency then begin
          log#f 2 "Too much latency! Resetting active sources.." ;
          Source.iter_outputs (fun s -> if s#is_active then s#output_reset) ;
          t0 := time () ;
          ticks := 0L ;
          acc := 0
        end else if
          (rem <= -1. || !acc >= 100) && !last_latency_log +. 1. < time ()
        then begin
          last_latency_log := time () ;
          log#f 2 "We must catchup %.2f seconds%s!"
            (-. rem)
            (if !acc <= 100 then "" else " (we've been late for 100 rounds)") ;
          acc := 0
        end
      end ;
      ticks := Int64.add !ticks 1L ;
      Source.iter_outputs (fun s -> s#output) ;
      Source.iter_outputs (fun s -> s#after_output)
  done ;

  sleep ()