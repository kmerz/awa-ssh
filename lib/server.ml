(*
 * Copyright (c) 2017 Christiano F. Haesbaert <haesbaert@haesbaert.org>
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

open Rresult.R
open Util

let version_banner = "SSH-2.0-awa_ssh_0.1"

type user = {
  name     : string;
  password : string option;
  keys     : Hostkey.pub list;
}

type auth_state =
  | Preauth
  | Inprogress of (string * string * int)
  | Done

type t = {
  client_version : string option;         (* Without crlf *)
  server_version : string;                (* Without crlf *)
  client_kexinit : Ssh.kexinit option;    (* Last KEXINIT received *)
  server_kexinit : Ssh.kexinit;           (* Last KEXINIT sent by us *)
  neg_kex        : Kex.negotiation option;(* Negotiated KEX *)
  host_key       : Hostkey.priv;          (* Server host key *)
  session_id     : Cstruct.t option;      (* First calculated H *)
  keys_ctos      : Kex.keys;              (* Client to server (input) keys *)
  keys_stoc      : Kex.keys;              (* Server to cleint (output) keys *)
  new_keys_ctos  : Kex.keys option;       (* Install when we receive NEWKEYS *)
  new_keys_stoc  : Kex.keys option;       (* Install after we send NEWKEYS *)
  input_buffer   : Cstruct.t;             (* Unprocessed input *)
  expect         : Ssh.message_id option; (* Messages to expect, None if any *)
  auth_state     : auth_state;		  (* username * service in progress *)
  user_db        : user list;             (* username database *)
  ignore_next_packet : bool;              (* Ignore the next packet from the wire *)
}

let guard_msg t msg =
  let open Ssh in
  match t.expect with
  | None -> ok ()
  | Some SSH_MSG_DISCONNECT -> ok ()
  | Some SSH_MSG_IGNORE -> ok ()
  | Some SSH_MSG_DEBUG -> ok ()
  | Some id ->
    let msgid = message_to_id msg in
    guard (id = msgid) ("Unexpected message " ^ (message_id_to_string msgid))

let make host_key user_db =
  let open Ssh in
  let banner_msg = Ssh_msg_version version_banner in
  let server_kexinit = Kex.make_kexinit () in
  let kex_msg = Ssh.Ssh_msg_kexinit server_kexinit in
  let t = { client_version = None;
            server_version = version_banner;
            server_kexinit;
            client_kexinit = None;
            neg_kex = None;
            host_key;
            session_id = None;
            keys_ctos = Kex.plaintext_keys;
            keys_stoc = Kex.plaintext_keys;
            new_keys_ctos = None;
            new_keys_stoc = None;
            input_buffer = Cstruct.create 0;
            expect = Some SSH_MSG_VERSION;
            auth_state = Preauth;
            user_db;
            ignore_next_packet = false }
  in
  t, [ banner_msg; kex_msg ]

let find_user t username =
  Util.find_some (fun user -> user.name = username) t.user_db

let find_key user key  =
  Util.find_some (fun key2 -> key = key2 ) user.keys

let find_user_key t user key =
  match find_user t user with
  | None -> None
  | Some user -> find_key user key

let of_buf t buf =
  { t with input_buffer = buf }

let patch_new_keys old_keys new_keys =
  let open Kex in
  let open Hmac in
  guard_some new_keys "No new_keys_ctos" >>= fun new_keys ->
  let new_mac = { new_keys.mac with seq = old_keys.mac.seq } in
  ok { new_keys with mac = new_mac }

let input_buf t buf =
  of_buf t (cs_join t.input_buffer buf)

let pop_msg2 t buf =
  let version t buf =
    Wire.get_version buf >>= fun (client_version, buf) ->
    match client_version with
    | None -> ok (t, None)
    | Some v ->
      let msg = Ssh.Ssh_msg_version v in
      ok (of_buf t buf, Some msg)
  in
  let decrypt t buf =
    Packet.decrypt t.keys_ctos buf >>= function
    | None -> ok (t, None)
    | Some (pkt, buf, keys_ctos) ->
      let ignore_packet = t.ignore_next_packet in
      Packet.to_msg pkt >>= fun msg ->
      let t = { t with keys_ctos; ignore_next_packet = false } in
      ok (of_buf t buf, if ignore_packet then None else Some msg)
  in
  match t.client_version with
  | None -> version t buf
  | Some _ -> decrypt t buf

let pop_msg t = pop_msg2 t t.input_buffer

let handle_userauth_request t username service auth_method =
  let open Ssh in
  (* Normal failure, let the poor soul try ag *)
  let fail t =
    match t.auth_state with
    | Preauth | Done -> error "Unexpected auth_state"
    | Inprogress (u, s, nfailed) ->
      let t = { t with auth_state = Inprogress (u, s, succ nfailed) } in
      ok (t, [ Ssh_msg_userauth_failure ([ "publickey"; "password" ], false) ])
  in
  (* Auth is done, further attempts should be silently ignored *)
  let success t =
    ok ({ t with auth_state = Done }, [ Ssh_msg_userauth_success ])
  in
  (* XXX need to handle this properly and close the connection *)
  let disconnect t =
    ok (t, [ Ssh_msg_disconnect
               (SSH_DISCONNECT_PROTOCOL_ERROR,
                "username or service changed during authentication",
                "") ])
  in
  let pk_ok t pubkey = ok (t, [ Ssh_msg_userauth_pk_ok pubkey ]) in
  let discard t = ok (t, []) in
  let try_auth t =
    (* XXX verify all fail cases, what should we do and so on *)
    guard_some t.session_id "No session_id" >>= fun session_id ->
    guard (service = "ssh-connection") "Bad service" >>= fun () ->
    match auth_method with
    (* Public key authentication probing *)
    | Pubkey (key_alg, pubkey, None) ->
      (match pubkey with
       | Hostkey.Rsa_pub rsa_pub ->
         if key_alg = Hostkey.sshname pubkey then
           pk_ok t pubkey
         else
           fail t
       | Hostkey.Unknown -> fail t)
    (* Public key authentication *)
    | Pubkey (key_alg, pubkey, Some signed) ->
      (guard (key_alg = Hostkey.sshname pubkey) "Key type mismatch"
       >>= fun () ->
       match find_user_key t username pubkey with
       | None -> fail t
       | Some pubkey ->
         let unsigned =
           let open Wire in
           put_cstring session_id (Dbuf.create ()) |>
           put_message_id SSH_MSG_USERAUTH_REQUEST |>
           put_string username |>
           put_string service |>
           put_string "publickey" |>
           put_bool true |>
           put_string (Hostkey.sshname pubkey) |>
           put_pubkey pubkey |>
           Dbuf.to_cstruct
         in
         match Hostkey.verify pubkey ~unsigned ~signed with
         | Ok () -> success t
         | Error e -> fail t)
    (* Password authentication *)
    | Password (password, None) ->
      (match find_user t username with
       | None -> fail t
       | Some user ->
         if user.password = Some password then success t else fail t)
    | Password (password, Some oldpassword) -> fail t (* Change of password *)
    (* Host based authentication, won't support *)
    | Hostbased _ -> fail t
    (* None authentication, won't support *)
    | Authnone -> fail t
  in
  match t.auth_state with
  | Done -> discard t
  | Preauth -> try_auth { t with auth_state = Inprogress (username, service, 0) }
  | Inprogress (prev_username, prev_service, nfailed) ->
    if nfailed >= 10 then
      error "Maximum attempts reached, we already sent a disconnect."
    else if prev_username = username && prev_service = service then
      try_auth t
    else
      disconnect t

let handle_msg t msg =
  let open Ssh in
  let open Nocrypto in
  guard_msg t msg >>= fun () ->
  match msg with
  | Ssh_msg_kexinit kex ->
    guard_some kex.input_buf "No kex input_buf kex" >>= fun _ ->
    Kex.negotiate ~s:t.server_kexinit ~c:kex
    >>= fun neg ->
    let ignore_next_packet =
      kex.first_kex_packet_follows &&
      not (Kex.guessed_right ~s:t.server_kexinit ~c:kex)
    in
    ok ({ t with client_kexinit = Some kex;
                 neg_kex = Some neg;
                 expect = Some SSH_MSG_KEXDH_INIT;
                 ignore_next_packet },
        [])
  | Ssh_msg_kexdh_init e ->
    guard_some t.neg_kex "No negotiated kex" >>= fun neg ->
    guard_some t.client_version "No client version" >>= fun client_version ->
    guard_none t.new_keys_stoc "Already got new_keys_stoc" >>= fun () ->
    guard_none t.new_keys_ctos "Already got new_keys_ctos" >>= fun () ->
    guard_some t.client_kexinit "No client kex" >>= fun c ->
    guard_some c.input_buf "No kex input_buf" >>= fun client_kexinit ->
    Kex.(Dh.generate neg.kex_alg e) >>= fun (y, f, k) ->
    let pub_host_key = Hostkey.pub_of_priv t.host_key in
    let h = Kex.Dh.compute_hash
        ~v_c:(Cstruct.of_string client_version)
        ~v_s:(Cstruct.of_string t.server_version)
        ~i_c:client_kexinit
        ~i_s:(Wire.blob_of_kexinit t.server_kexinit)
        ~k_s:(Wire.blob_of_pubkey pub_host_key)
        ~e ~f ~k
    in
    let signature = Hostkey.sign t.host_key h in
    let session_id = match t.session_id with None -> h | Some x -> x in
    let new_keys_ctos, new_keys_stoc = Kex.Dh.derive_keys k h session_id neg in
    ok ({t with session_id = Some session_id;
                new_keys_ctos = Some new_keys_ctos;
                new_keys_stoc = Some new_keys_stoc;
                expect = Some SSH_MSG_NEWKEYS },
        [ Ssh_msg_kexdh_reply (pub_host_key, f, signature);
          Ssh_msg_newkeys ])
  | Ssh_msg_newkeys ->
    (* If this is the first time we keyed, we must take a service request *)
    let expect = if t.keys_ctos = Kex.plaintext_keys then
        Some SSH_MSG_SERVICE_REQUEST
      else
        None
    in
    patch_new_keys t.keys_ctos t.new_keys_ctos >>= fun new_keys_ctos ->
    (* paranoia *)
    assert (new_keys_ctos <> Kex.plaintext_keys);
    ok ({ t with keys_ctos = new_keys_ctos;
                 new_keys_ctos = None;
                 expect },
        [])
  | Ssh_msg_service_request service ->
    if service = "ssh-userauth" then
      ok ({ t with expect = Some SSH_MSG_USERAUTH_REQUEST },
          [ Ssh_msg_service_accept service ])
    else
      (* XXX need to tell user to close socket when we send a disconnect. *)
      let msg =
        Ssh_msg_disconnect
          (SSH_DISCONNECT_SERVICE_NOT_AVAILABLE,
           (sprintf "service %s not available" service), "")
      in
      ok (t, [ msg ])
  | Ssh_msg_userauth_request (username, service, auth_method) ->
    handle_userauth_request t username service auth_method
  | Ssh_msg_version v ->
    ok ({ t with client_version = Some v;
                 expect = Some SSH_MSG_KEXINIT }, [])
  | msg -> error ("unhandled msg: " ^ (message_to_string msg))

let output_msg t msg =
  (match msg with
   | Ssh.Ssh_msg_version v ->
     ok (t, Cstruct.of_string (v ^ "\r\n"))
   | msg ->
     let enc, keys = Packet.encrypt t.keys_stoc msg in
     ok ({ t with keys_stoc = keys }, enc))
  >>= fun (t, buf) ->
  (* Do state transitions *)
  match msg with
  | Ssh.Ssh_msg_newkeys ->
    patch_new_keys t.keys_stoc t.new_keys_stoc >>= fun new_keys_stoc ->
    let t = { t with keys_stoc = new_keys_stoc;
                     new_keys_stoc = None }
    in
    ok (t, buf)
  | _ -> ok (t, buf)

let output_msgs t = function
  | [] -> invalid_arg "empty msg list"
  | [msg] -> output_msg t msg
  | msgs ->
    List.fold_left
      (fun a msg ->
         a >>= fun (t, buf) ->
         output_msg t msg >>= fun (t, msgbuf) ->
         ok (t, Cstruct.append buf msgbuf))
      (ok (t, Cstruct.create 0))
      msgs
