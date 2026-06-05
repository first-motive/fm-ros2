// First Motive OpenArm teleop panel.
//
// Publishes the two command streams MoveIt Servo consumes:
//   geometry_msgs/TwistStamped -> /servo_node/delta_twist_cmds  (Cartesian jog)
//   control_msgs/JointJog      -> /servo_node/delta_joint_cmds  (per-joint jog)
//
// Commands are unitless ([-1, 1]); Servo scales them (servo.yaml). Buttons send a
// short burst while held via a repeat timer, matching Servo's incoming_command_timeout.
//
// This is the scalable teleop spine: a new operator opens a Foxglove URL — no
// per-operator hardware. Build + install with the scripts in package.json (needs
// Node + the create-foxglove-extension toolchain); not built by the ROS workspace.

import { ExtensionContext, PanelExtensionContext } from "@foxglove/extension";
import { ReactElement, useEffect, useLayoutEffect, useRef, useState } from "react";
import { createRoot } from "react-dom/client";

const TWIST_TOPIC = "/servo_node/delta_twist_cmds";
const JOINT_TOPIC = "/servo_node/delta_joint_cmds";
const COMMAND_FRAME = "openarm_right_base_link";
const JOINTS = Array.from({ length: 7 }, (_, i) => `openarm_right_joint${i + 1}`);
const REPEAT_MS = 50;

type Axis = "linear" | "angular";

function TeleopPanel({ context }: { context: PanelExtensionContext }): ReactElement {
  const [renderDone, setRenderDone] = useState<(() => void) | undefined>();
  // Active command refreshed by the repeat timer while a button is held.
  const held = useRef<{ kind: "twist" | "joint"; payload: unknown } | undefined>();

  useLayoutEffect(() => {
    context.onRender = (_state, done) => setRenderDone(() => done);
    context.advertise?.(TWIST_TOPIC, "geometry_msgs/msg/TwistStamped");
    context.advertise?.(JOINT_TOPIC, "control_msgs/msg/JointJog");
    return () => {
      context.unadvertise?.(TWIST_TOPIC);
      context.unadvertise?.(JOINT_TOPIC);
    };
  }, [context]);

  // Re-publish the held command on a timer so Servo keeps moving while pressed.
  useEffect(() => {
    const timer = setInterval(() => {
      const cmd = held.current;
      if (!cmd) return;
      const stamp = nowStamp();
      if (cmd.kind === "twist") {
        const { axis, field, value } = cmd.payload as TwistCmd;
        context.publish?.(TWIST_TOPIC, twistMsg(stamp, axis, field, value));
      } else {
        const { joint, value } = cmd.payload as JointCmd;
        context.publish?.(JOINT_TOPIC, jointMsg(stamp, joint, value));
      }
    }, REPEAT_MS);
    return () => clearInterval(timer);
  }, [context]);

  useEffect(() => renderDone?.(), [renderDone]);

  const start = (cmd: { kind: "twist" | "joint"; payload: unknown }) => {
    held.current = cmd;
  };
  const stop = () => {
    held.current = undefined;
  };

  return (
    <div style={{ padding: "0.75rem", fontFamily: "sans-serif" }}>
      <h3 style={{ marginTop: 0 }}>OpenArm Teleop → Servo</h3>
      <Section title="Cartesian (m/s · rad/s, unitless)">
        {(["linear", "angular"] as Axis[]).map((axis) =>
          (["x", "y", "z"] as const).map((field) => (
            <JogButton
              key={`${axis}-${field}`}
              label={`${axis[0]}${field}`}
              onDown={(sign) => start({ kind: "twist", payload: { axis, field, value: sign } })}
              onUp={stop}
            />
          )),
        )}
      </Section>
      <Section title="Per-joint">
        {JOINTS.map((joint, i) => (
          <JogButton
            key={joint}
            label={`j${i + 1}`}
            onDown={(sign) => start({ kind: "joint", payload: { joint, value: sign } })}
            onUp={stop}
          />
        ))}
      </Section>
    </div>
  );
}

type TwistCmd = { axis: Axis; field: "x" | "y" | "z"; value: number };
type JointCmd = { joint: string; value: number };

function nowStamp() {
  const now = Date.now();
  return { sec: Math.floor(now / 1000), nsec: (now % 1000) * 1e6 };
}

function twistMsg(stamp: { sec: number; nsec: number }, axis: Axis, field: string, value: number) {
  const linear = { x: 0, y: 0, z: 0 };
  const angular = { x: 0, y: 0, z: 0 };
  (axis === "linear" ? linear : angular)[field as "x" | "y" | "z"] = value;
  return { header: { stamp, frame_id: COMMAND_FRAME }, twist: { linear, angular } };
}

function jointMsg(stamp: { sec: number; nsec: number }, joint: string, value: number) {
  return {
    header: { stamp, frame_id: COMMAND_FRAME },
    joint_names: [joint],
    velocities: [value],
    displacements: [],
    duration: 0,
  };
}

function Section({ title, children }: { title: string; children: React.ReactNode }): ReactElement {
  return (
    <div style={{ marginBottom: "0.75rem" }}>
      <div style={{ fontSize: "0.8rem", opacity: 0.7, marginBottom: "0.25rem" }}>{title}</div>
      <div style={{ display: "flex", flexWrap: "wrap", gap: "0.25rem" }}>{children}</div>
    </div>
  );
}

// A pair of +/- buttons. Holding publishes a sustained command; release stops.
function JogButton({
  label,
  onDown,
  onUp,
}: {
  label: string;
  onDown: (sign: number) => void;
  onUp: () => void;
}): ReactElement {
  return (
    <div style={{ display: "flex", flexDirection: "column", alignItems: "center" }}>
      <button onPointerDown={() => onDown(1)} onPointerUp={onUp} onPointerLeave={onUp}>
        {label}+
      </button>
      <button onPointerDown={() => onDown(-1)} onPointerUp={onUp} onPointerLeave={onUp}>
        {label}-
      </button>
    </div>
  );
}

export function activate(extensionContext: ExtensionContext): void {
  extensionContext.registerPanel({
    name: "OpenArm Teleop",
    initPanel: (context: PanelExtensionContext) => {
      const root = createRoot(context.panelElement);
      root.render(<TeleopPanel context={context} />);
      return () => root.unmount();
    },
  });
}
