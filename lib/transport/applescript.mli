(** AppleScript Transport - Execute AppleScript via osascript *)

(** Result of AppleScript execution *)
type result = {
  success : bool;
  output : string;
  error : string option;
}

(** Execute AppleScript code and return result *)
val execute : string -> result

(** Execute AppleScript from file *)
val execute_file : string -> result

(** Check if an application is running *)
val is_app_running : string -> bool

(** Activate (bring to front) an application *)
val activate_app : string -> result

(** Quit an application *)
val quit_app : string -> result

(** Modifier keys for keystrokes *)
type modifier = [ `Command | `Shift | `Option | `Control ]

(** Send keystroke to application *)
val send_keystroke : string -> string -> ?modifiers:modifier list -> unit -> result

(** Send key code to application *)
val send_keycode : string -> int -> ?modifiers:modifier list -> unit -> result

(** Common key codes *)
module KeyCode : sig
  val space : int
  val return_key : int
  val escape : int
  val tab : int
  val delete : int
  val left : int
  val right : int
  val up : int
  val down : int
  val home : int
  val end_key : int
  val page_up : int
  val page_down : int
  val f1 : int
  val f2 : int
  val f3 : int
  val f4 : int
  val f5 : int
  val f6 : int
  val f7 : int
  val f8 : int
  val f9 : int
  val f10 : int
  val f11 : int
  val f12 : int
end

(** Click menu item (path separated by /) *)
val click_menu : string -> string -> result
