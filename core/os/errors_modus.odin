#+private
#+build modus
package os

import "core:sys/modus"

// Must be an enum <= 4 bytes with a 0 member so `os.Error` (`union #shared_nil`) stays 8 bytes.
_Platform_Error :: enum i32 {
	NONE = 0,
}

_error_string :: proc(errno: i32) -> string {
	if errno <= 0 || errno > i32(max(modus.Call_Outcome)) {
		return "" if errno == 0 else "<unknown platform error>"
	}
	switch modus.Call_Outcome(errno) {
	case .Succeeded:                        return ""
	case .Argument_Refused:                 return "argument refused"
	case .Nothing_Has_That_Name:            return "nothing has that name"
	case .Name_Already_Taken:               return "name already taken"
	case .Grant_Or_Right_Missing:           return "grant or right missing"
	case .Callee_Busy:                      return "callee busy"
	case .Budget_Or_Capacity_Exhausted:     return "budget or capacity exhausted"
	case .Wrong_State:                      return "wrong state"
	case .Another_Change_Came_First:        return "another change came first"
	case .Operation_Unsupported:            return "operation unsupported"
	case .Data_Damaged:                     return "data damaged"
	case .Callee_Unavailable:               return "callee unavailable"
	case .Stopped_After_A_Partial_Change:   return "stopped after a partial change"
	case .Callee_Stopped_During_The_Call:   return "callee stopped during the call"
	case .Connection_Ended_During_The_Call: return "connection ended during the call"
	case .Deadline_Passed_During_The_Call:  return "deadline passed during the call"
	case .Answer_Unreadable:                return "answer unreadable"
	}
	return "<unknown platform error>"
}

_modus_outcome_to_error :: proc(outcome: modus.Call_Outcome) -> Error {
	switch outcome {
	case .Succeeded:
		return nil
	case .Nothing_Has_That_Name:
		return .Not_Exist
	case .Name_Already_Taken:
		return .Exist
	case .Grant_Or_Right_Missing:
		return .Permission_Denied
	case .Budget_Or_Capacity_Exhausted:
		return .Out_Of_Memory
	case .Operation_Unsupported:
		return .Unsupported
	case .Deadline_Passed_During_The_Call:
		return .Timeout
	case .Argument_Refused,
	     .Callee_Busy,
	     .Wrong_State,
	     .Another_Change_Came_First,
	     .Data_Damaged,
	     .Callee_Unavailable,
	     .Stopped_After_A_Partial_Change,
	     .Callee_Stopped_During_The_Call,
	     .Connection_Ended_During_The_Call,
	     .Answer_Unreadable:
		return Platform_Error(outcome)
	}
	return Platform_Error(outcome)
}
