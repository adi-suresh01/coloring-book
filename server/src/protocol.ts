export type Point = {
  x: number;
  y: number;
  pressure: number;
  t: number;
};

export type Color = {
  r: number;
  g: number;
  b: number;
  a: number;
};

export type Tool = "sketchpen" | "pencil" | "watercolor" | "crayon" | "pastel";

export type StrokeHeader = {
  id: string;
  userId: string;
  tool: Tool;
  color: Color;
  brushSize: number;
};

export type Stroke = StrokeHeader & {
  points: Point[];
  complete: boolean;
};

export type Peer = {
  userId: string;
  name: string;
  color: string;
  cursor?: { x: number; y: number };
};

export type Page = {
  pageId: string;
  displayName: string;
  mimeType: string;       // "image/png"
  imageBase64: string;    // may be empty string for blank paper
};

export type ClientMessage =
  | { type: "stroke_start"; stroke: StrokeHeader & { point: Point } }
  | { type: "stroke_point"; strokeId: string; point: Point }
  | { type: "stroke_end"; strokeId: string }
  | { type: "cursor"; x: number; y: number }
  | { type: "set_page"; page: Page | null }
  | { type: "clear_canvas" };

export type ServerMessage =
  | {
      type: "room_state";
      strokes: Stroke[];
      peers: Peer[];
      you: { userId: string };
      page: Page | null;
    }
  | { type: "peer_joined"; peer: Peer }
  | { type: "peer_left"; userId: string }
  | {
      type: "stroke_start";
      userId: string;
      stroke: StrokeHeader & { point: Point };
    }
  | { type: "stroke_point"; userId: string; strokeId: string; point: Point }
  | { type: "stroke_end"; userId: string; strokeId: string }
  | { type: "cursor"; userId: string; x: number; y: number }
  | { type: "page_changed"; userId: string; page: Page | null }
  | { type: "canvas_cleared"; userId: string };
