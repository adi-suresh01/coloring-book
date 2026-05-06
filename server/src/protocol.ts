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

/// A page is a coloring sheet with its own image + its own strokes.
/// Each room owns multiple pages; only one is "active" at any time.
export type Page = {
  pageId: string;
  displayName: string;
  mimeType: string;       // "image/png"
  imageBase64: string;    // empty string for blank paper
};

/// On-the-wire stroke that knows which page it belongs to (so peers can
/// route incoming stroke events to the correct page's stroke list).
export type WireStroke = StrokeHeader & {
  pageId: string;
  points: Point[];
  complete: boolean;
};

export type ClientMessage =
  | { type: "stroke_start"; stroke: StrokeHeader & { point: Point; pageId: string } }
  | { type: "stroke_point"; strokeId: string; point: Point }
  | { type: "stroke_end"; strokeId: string }
  | { type: "cursor"; x: number; y: number }
  | { type: "add_page"; page: Page }                  // creates new + makes active
  | { type: "select_page"; pageId: string }            // switch active page
  | { type: "delete_page"; pageId: string }            // remove page (and its strokes)
  | { type: "clear_canvas" };                          // clears active page's strokes

export type ServerMessage =
  | {
      type: "room_state";
      peers: Peer[];
      you: { userId: string };
      pages: Page[];
      activePageId: string | null;
      strokes: WireStroke[];
    }
  | { type: "peer_joined"; peer: Peer }
  | { type: "peer_left"; userId: string }
  | {
      type: "stroke_start";
      userId: string;
      stroke: StrokeHeader & { point: Point; pageId: string };
    }
  | { type: "stroke_point"; userId: string; strokeId: string; point: Point }
  | { type: "stroke_end"; userId: string; strokeId: string }
  | { type: "cursor"; userId: string; x: number; y: number }
  | { type: "page_added"; userId: string; page: Page }
  | { type: "page_selected"; userId: string; pageId: string }
  | { type: "page_deleted"; userId: string; pageId: string }
  | { type: "canvas_cleared"; userId: string; pageId: string };
