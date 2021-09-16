open Lwt.Infix

module Transport : Dns_client.S
 with type io_addr = Ipaddr.t * int
 and type +'a io = 'a Lwt.t
 and type stack = unit
= struct
  type io_addr = Ipaddr.t * int
  type ns_addr = Dns.proto * io_addr
  type +'a io = 'a Lwt.t
  type stack = unit
  type t = {
    nameserver : ns_addr ;
    timeout_ns : int64 ;
  }
  type context = {
    t : t ;
    fd : Lwt_unix.file_descr ;
    mutable timeout_ns : int64
  }

  let read_file file =
    try
      let fh = open_in file in
      try
        let content = really_input_string fh (in_channel_length fh) in
        close_in_noerr fh ;
        Ok content
      with _ ->
        close_in_noerr fh;
        Error (`Msg ("Error reading file: " ^ file))
    with _ -> Error (`Msg ("Error opening file " ^ file))

  let create ?nameserver ~timeout () =
    let nameserver =
      Rresult.R.(get_ok (of_option ~none:(fun () ->
          let ip =
            match
              read_file "/etc/resolv.conf" >>= fun data ->
              Dns_resolvconf.parse data >>= fun nameservers ->
              List.fold_left (fun acc ns ->
                  match acc, ns with
                  | Ok ip, _ -> Ok ip
                  | _, `Nameserver ip -> Ok ip)
                (Error (`Msg "no nameserver")) nameservers
            with
            | Error _ -> Ipaddr.(V4 (V4.of_string_exn (fst Dns_client.default_resolver)))
            | Ok ip -> ip
          in
          Ok (`Tcp, (ip, 53)))
          nameserver))
    in
    { nameserver ; timeout_ns = timeout }

  let nameserver { nameserver ; _ } = nameserver
  let rng = Mirage_crypto_rng.generate ?g:None
  let clock = Mtime_clock.elapsed_ns

  let with_timeout ctx f =
    let timeout =
      Lwt_unix.sleep (Duration.to_f ctx.timeout_ns) >|= fun () ->
      Error (`Msg "DNS request timeout")
    in
    let start = clock () in
    Lwt.pick [ f ; timeout ] >|= fun result ->
    let stop = clock () in
    ctx.timeout_ns <- Int64.sub ctx.timeout_ns (Int64.sub stop start);
    result

  let close { fd ; _ } =
    Lwt.catch (fun () -> Lwt_unix.close fd) (fun _ -> Lwt.return_unit)

  let send ctx tx =
    let open Lwt in
    Lwt.catch (fun () ->
      with_timeout ctx
      (Lwt_unix.send ctx.fd (Cstruct.to_bytes tx) 0
        (Cstruct.length tx) [] >>= fun res ->
      if res <> Cstruct.length tx then
        Lwt_result.fail (`Msg ("oops" ^ (string_of_int res)))
      else
        Lwt_result.return ()))
     (fun e -> Lwt.return (Error (`Msg (Printexc.to_string e))))

  let recv ctx =
    let open Lwt in
    let recv_buffer = Bytes.make 2048 '\000' in
    Lwt.catch (fun () ->
      with_timeout ctx
        (Lwt_unix.recv ctx.fd recv_buffer 0 (Bytes.length recv_buffer) []
        >>= fun read_len ->
        if read_len > 0 then
          Lwt_result.return (Cstruct.of_bytes ~len:read_len recv_buffer)
        else
          Lwt_result.fail (`Msg "Empty response")))
    (fun e -> Lwt_result.fail (`Msg (Printexc.to_string e)))

  let bind = Lwt.bind
  let lift = Lwt.return

  let connect ?nameserver:ns t =
    let (proto, (server, port)) =
      match ns with None -> nameserver t | Some x -> x
    in
    Lwt.catch (fun () ->
        Lwt_unix.(match proto with
            | `Udp -> getprotobyname "udp" >|= fun x -> x.p_proto, SOCK_DGRAM
            | `Tcp -> getprotobyname "tcp" >|= fun x -> x.p_proto, SOCK_STREAM)
        >>= fun (proto_number, socket_type) ->
        let fam =
          match server with
          | Ipaddr.V4 _ -> Lwt_unix.PF_INET
          | Ipaddr.V6 _ -> Lwt_unix.PF_INET6
        in
        let socket = Lwt_unix.socket fam socket_type proto_number in
        let addr = Lwt_unix.ADDR_INET (Ipaddr_unix.to_inet_addr server, port) in
        let ctx = { t ; fd = socket ; timeout_ns = t.timeout_ns } in
        Lwt.catch (fun () ->
            (* SO_RCVTIMEO does not work in Lwt: it results in an EAGAIN, which
               is handled by re-queuing the event *)
            with_timeout ctx
              (Lwt_unix.connect socket addr >|= fun () -> Ok ()) >>= function
              | Ok () -> Lwt_result.return ctx
              | Error e -> close ctx >|= fun () -> Error e)
          (fun e ->
             close ctx >|= fun () ->
             Error (`Msg (Printexc.to_string e))))
      (fun e ->
         Lwt_result.fail (`Msg (Printexc.to_string e)))
end

(* Now that we have our {!Transport} implementation we can include the logic
   that goes on top of it: *)
include Dns_client.Make(Transport)

(* initialize the RNG *)
let () = Mirage_crypto_rng_lwt.initialize ()
