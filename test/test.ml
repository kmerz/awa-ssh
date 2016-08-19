(*
 * Copyright (c) 2016 Christiano F. Haesbaert <haesbaert@haesbaert.org>
 *
 * Permission to use, copy, modify, and distribute this software for any
 * purpose with or without fee is hereby granted, provided that the above
 * copyright notice and this permission notice appear in all copies.
 *
 * THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
 * WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
 * MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
 * ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
 * WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
 * ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
 * OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
 *)

let () = Printexc.record_backtrace true

let printf = Printf.printf

let tty_out = Unix.isatty Unix.stdout
let colored_or_not cfmt fmt =
  if tty_out then (Printf.sprintf cfmt) else (Printf.sprintf fmt)
let red fmt    = colored_or_not ("\027[31m"^^fmt^^"\027[m") fmt
let green fmt  = colored_or_not ("\027[32m"^^fmt^^"\027[m") fmt
let yellow fmt = colored_or_not ("\027[33m"^^fmt^^"\027[m") fmt
let blue fmt   = colored_or_not ("\027[36m"^^fmt^^"\027[m") fmt

let t_banner () =
  let open Ssh_trans in
  let c, _ = make () in
  let good_strings = [
    "SSH-2.0-foobar lalal\r\n";
    "\r\n\r\nSSH-2.0-foobar lalal\r\n";
    "SSH-2.0-foobar lalal lololo\r\n";
    "SSH-2.0-OpenSSH_6.9\r\n";
    "Some crap before\r\nSSH-2.0-OpenSSH_6.9\r\n";
    "SSH-2.0-OpenSSH_6.9\r\nSomeCrap After\r\n";
  ]
  in
  List.iter (fun s ->
      let c = add_buf c (Cstruct.of_string s) |> process in
      assert (c.state = Ssh_trans.Version_exchanged))
    good_strings;
  let bad_strings = [
    "SSH-2.0\r\n";
    "SSH-1.0-foobar lalal lololo\r\n";
    "SSH-2.0-Open-SSH_6.9\r\n";
    "Some crap before\r\nSSH-2.0-Open-SSH_6.9\r\n";
    "\r\nSSH-2.0-Open-SSH_6.9\r\nSom crap after";
  ]
  in
  List.iter (fun s ->
      let ok = try
          ignore @@ (add_buf c (Cstruct.of_string s) |> process);
          false
        with
          Failure _ -> true
      in
      if not ok then
        failwith ("bad string " ^ s ^ " should have failed"))
    bad_strings;
  (* Check if we can extract client_version *)
  let cx = add_buf c (Cstruct.of_string "SSH-2.0-OpenSSH_6.9\r\n") |> process in
  assert (cx.peer_version = "OpenSSH_6.9");
  assert (Cstruct.len (cx.buffer) = 0);
  (* If we have multiple lines, check if we consume the buffer correctly *)
  let cx = add_buf c
      (Cstruct.of_string "Foo bar\r\nSSH-2.0-OpenSSH_6.9\r\n") |> process
  in
  assert (cx.peer_version = "OpenSSH_6.9");
  assert (Cstruct.len (cx.buffer) = 0);
  let cx = add_buf c
      (Cstruct.of_string "Foo bar\r\nSSH-2.0-OpenSSH_6.9\r\nLALA") |> process
  in
  assert (cx.peer_version = "OpenSSH_6.9");
  assert (Cstruct.len (cx.buffer) = 4)

let run_test test =
  let f = fst test in
  let name = snd test in
  printf "%s %-40s%!" (blue "%s" "Test") (yellow "%s" name);
  let () = try f () with
      exn -> printf "%s\n%!" (red "failed");
      raise exn
  in
  printf "%s\n%!" (green "ok")

let all_tests = [
  (t_banner, "version banner");
]

let _ =
  List.iter run_test all_tests;