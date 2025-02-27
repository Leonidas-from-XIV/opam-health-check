open Lwt.Syntax

module Make (Backend : Backend_intf.S) = struct
  let serv_text ~content_type body =
    let headers = Cohttp.Header.init_with "Content-Type" content_type in
    Cohttp_lwt_unix.Server.respond_string ~headers ~status:`OK ~body ()

  let option_to_string = function
    | None -> ""
    | Some s -> s

  let get_query_param_list uri name =
    Uri.query uri |>
    List.fold_left begin fun acc (k, v) ->
      if String.equal k name then v @ acc else acc
    end [] |>
    List.rev

  let parse_raw_query logdir uri =
    let checkbox_default def = if List.is_empty (Uri.query uri) then def else false in
    let compilers = get_query_param_list uri "comp" in
    let show_available = get_query_param_list uri "available" in
    let show_failures_only = option_to_string (Uri.get_query_param uri "show-failures-only") in
    let show_failures_only = if String.is_empty show_failures_only then checkbox_default false else bool_of_string show_failures_only in
    let show_only = get_query_param_list uri "show-only" in
    let show_diff_only = option_to_string (Uri.get_query_param uri "show-diff-only") in
    let show_diff_only = if String.is_empty show_diff_only then checkbox_default false else bool_of_string show_diff_only in
    let show_latest_only = option_to_string (Uri.get_query_param uri "show-latest-only") in
    let show_latest_only = if String.is_empty show_latest_only then checkbox_default true else bool_of_string show_latest_only in
    let sort_by_revdeps = option_to_string (Uri.get_query_param uri "sort-by-revdeps") in
    let sort_by_revdeps = if String.is_empty sort_by_revdeps then checkbox_default false else bool_of_string sort_by_revdeps in
    let maintainers = option_to_string (Uri.get_query_param uri "maintainers") in
    let maintainers = if String.is_empty maintainers then None else Some maintainers in
    let maintainers = (option_to_string maintainers, Option.map (Re.Posix.compile_pat ~opts:[`ICase]) maintainers) in
    let logsearch = option_to_string (Uri.get_query_param uri "logsearch") in
    let logsearch = if String.is_empty logsearch then None else Some logsearch in
    let logsearch' =
      Option.map2 begin fun re comp ->
        (Re.Posix.compile_pat ~opts:[`Newline] re, Intf.Compiler.from_string comp)
      end logsearch (Uri.get_query_param uri "logsearch_comp")
    in
    let logsearch = (option_to_string logsearch, logsearch') in
    let* available_compilers = Cache.get_compilers ~logdir Backend.cache in
    let compilers = match compilers with
      | [] -> available_compilers
      | compilers -> List.map Intf.Compiler.from_string compilers
    in
    let show_available = match show_available with
      | [] -> compilers
      | show_available -> List.map Intf.Compiler.from_string show_available
    in
    let show_only = match show_only with
      | [] when show_failures_only -> [Intf.State.Bad; Intf.State.Partial]
      | [] -> Intf.State.all
      | show_only -> List.map Intf.State.from_string show_only
    in
    Lwt.return {
      Html.available_compilers;
      Html.compilers;
      Html.show_available;
      Html.show_only;
      Html.show_diff_only;
      Html.show_latest_only;
      Html.sort_by_revdeps;
      Html.maintainers;
      Html.logsearch;
    }

  let filter_path path =
    let path = List.filter (fun file -> not (String.is_empty file)) path in
    if not (List.for_all Oca_lib.is_valid_filename path) then
      failwith "Forbidden path";
    path

  let path_from_uri uri =
    match Uri.path uri with
    | "" -> []
    | path -> filter_path (Fpath.segs (Fpath.v path))

  let get_logdir name =
    let+ logdirs = Cache.get_logdirs Backend.cache in
    List.find_opt (fun logdir ->
      String.equal (Server_workdirs.get_logdir_name logdir) name
    ) logdirs

  let callback ~conf backend _conn req body_NOT_USED =
    let* () = Cohttp_lwt.Body.drain_body body_NOT_USED in
    let uri = Cohttp.Request.uri req in
    let get_log ~logdir ~comp ~state ~pkg =
      let* v = get_logdir logdir in
      match v with
      | None ->
          Cohttp_lwt_unix.Server.respond ~body:`Empty ~status:`Not_found ()
      | Some logdir ->
          let comp = Intf.Compiler.from_string comp in
          let state = Intf.State.from_string state in
          let* v = Backend.get_log backend ~logdir ~comp ~state ~pkg in
          match v with
          | None ->
              Cohttp_lwt_unix.Server.respond ~body:`Empty ~status:`Not_found ()
          | Some log ->
              let html = Html.get_log ~comp ~pkg log in
              serv_text ~content_type:"text/html; charset=utf-8" html
    in
    match path_from_uri uri with
    | [] -> (
        let* v = Cache.get_latest_logdir Backend.cache in
        match v with
        | None ->
            serv_text ~content_type:"text/plain"
              "opam-health-check: no run exists, please wait for the first run \
               to finish. Please look at the documentation to learn how to \
               start it.\n"
        | Some logdir ->
            let* query = parse_raw_query logdir uri in
            let* html = Cache.get_html ~conf Backend.cache query logdir in
            serv_text ~content_type:"text/html" html)
    | ["run"] ->
        let* html = Cache.get_html_run_list Backend.cache in
        serv_text ~content_type:"text/html" html
    | ["run";logdir] -> (
        let* v = get_logdir logdir in
        match v with
        | None ->
            Cohttp_lwt_unix.Server.respond ~body:`Empty ~status:`Not_found ()
        | Some logdir ->
            let* query = parse_raw_query logdir uri in
            let* html = Cache.get_html ~conf Backend.cache query logdir in
            serv_text ~content_type:"text/html" html)
    | ["diff"] ->
        let* html = Cache.get_html_diff_list Backend.cache in
        serv_text ~content_type:"text/html" html
    | ["diff"; range] -> (
        let (old_logdir, new_logdir) = match String.split_on_char '.' range with
          | [old_logdir; ""; new_logdir] -> (old_logdir, new_logdir)
          | _ -> assert false
        in
        let* v = get_logdir old_logdir in
        match v with
        | None ->
            Cohttp_lwt_unix.Server.respond ~body:`Empty ~status:`Not_found ()
        | Some old_logdir -> (
            let* v = get_logdir new_logdir in
            match v with
            | None ->
                Cohttp_lwt_unix.Server.respond ~body:`Empty ~status:`Not_found ()
            | Some new_logdir ->
                let* html = Cache.get_html_diff ~conf ~old_logdir ~new_logdir Backend.cache in
                serv_text ~content_type:"text/html" html))
    | ["log"; logdir; comp; state; pkg] ->
        get_log ~logdir ~comp ~state ~pkg
    | ["api"; "v1"; "latest"; "packages"] ->
        let* json = Cache.get_json_latest_packages Backend.cache in
        serv_text ~content_type:"application/json" json
    | ["metrics"] ->
        let* data = Prometheus.CollectorRegistry.(collect default) in
        let body = Fmt.to_to_string Prometheus_app.TextFormat_0_0_4.output data in
        serv_text ~content_type:"text/plain" body
    | _ ->
        Cohttp_lwt_unix.Server.respond ~body:`Empty ~status:`Not_found ()

  let callback ~debug ~conf backend conn req body =
    (* TODO: Try to understand why it wouldn't do anything before when this was ~on_exn *)
    Lwt.catch (fun () -> callback ~conf backend conn req body)
      (fun e ->
        if debug then begin
          let uri = Uri.to_string (Cohttp.Request.uri req) in
          let e = Printexc.to_string e in
          prerr_endline ("Exception while serving the page \""^uri^"\" raised: "^e);
          prerr_endline (Printexc.get_backtrace ());
        end;
        Lwt.fail e)

  let tcp_server port callback =
    Cohttp_lwt_unix.Server.create
      ~mode:(`TCP (`Port port))
      (Cohttp_lwt_unix.Server.make ~callback ())

  let main ~debug ~cap_file ~workdir =
    Printexc.record_backtrace debug;
    let* cwd = Lwt_unix.getcwd () in
    let workdir = Server_workdirs.create ~cwd ~workdir in
    let* () = Server_workdirs.init_base workdir in
    let conf = Server_configfile.from_workdir workdir in
    let port = Server_configfile.port conf in
    let* (backend, backend_task) = Backend.start ~debug ~cap_file conf workdir in
    Lwt.join [
      tcp_server port (callback ~debug ~conf backend);
      backend_task ();
    ]
end
