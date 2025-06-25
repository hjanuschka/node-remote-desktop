# ScreenCapture7 API Specification

A native macOS screen capture server with embedded web UI for remote desktop control.

## Base URL
```
http://localhost:3030
```

## Authentication
No authentication required. All endpoints are publicly accessible.

## Web Interface

### GET /
**Description:** Serves the embedded web UI for remote desktop control

**Response:**
- **Content-Type:** `text/html`
- **Status:** 200 OK
- **Body:** Complete HTML page with embedded CSS and JavaScript

### GET /index.html
**Description:** Alias for `/` - serves the same web UI

**Response:** Same as `/`

---

## Display Information

### GET /display
**Description:** Returns display information including resolution and scale factor

**Response:**
```json
{
  "physicalWidth": 3024,
  "physicalHeight": 1964,
  "boundsWidth": 1512.0,
  "boundsHeight": 982.0,
  "scaleFactor": 2.0
}
```

**Fields:**
- `physicalWidth`: Physical pixel width of the display
- `physicalHeight`: Physical pixel height of the display  
- `boundsWidth`: Logical coordinate width
- `boundsHeight`: Logical coordinate height
- `scaleFactor`: Retina scale factor (physical/logical)

---

## Window Management

### GET /windows
**Description:** Returns list of capturable windows

**Response:**
```json
[
  {
    "id": 1,
    "cgWindowID": 12345,
    "title": "Safari - Google",
    "app": "Safari",
    "position": {
      "x": 100,
      "y": 200
    },
    "size": {
      "width": 1200,
      "height": 800
    }
  }
]
```

**Fields:**
- `id`: Sequential window ID for API calls
- `cgWindowID`: Core Graphics window identifier
- `title`: Window title
- `app`: Application name
- `position`: Window position on screen
- `size`: Window dimensions

### GET /apps
**Description:** Returns list of applications (currently returns desktop only)

**Response:**
```json
{
  "applications": [
    {
      "id": 0,
      "name": "Full Desktop",
      "type": "desktop"
    }
  ]
}
```

---

## Screen Capture

### POST /capture
**Description:** Start screen capture session

**Request Body:**
```json
{
  "type": 0,
  "index": 0,
  "vp9": false
}
```

**Parameters:**
- `type`: Capture type (0=full desktop, 2=window)
- `index`: Window ID (0 for desktop, window ID for specific window)
- `vp9`: Quality mode (false=standard, true=high quality)

**Response:**
```json
{
  "status": "started",
  "type": 0,
  "index": 0,
  "mode": "High Quality JPEG"
}
```

### GET /frame
**Description:** Get current frame as JPEG image

**Query Parameters:**
- Optional timestamp for cache busting: `/frame?1234567890`

**Response:**
- **Content-Type:** `image/jpeg`
- **Status:** 200 OK
- **Body:** JPEG image data

**Quality:**
- Standard mode: 75% quality, max 1920px
- High Quality mode: 95% quality, max 3840px

---

## Mouse Control

### POST /click
**Description:** Perform mouse click on desktop

**Request Body:**
```json
{
  "x": 500,
  "y": 300
}
```

**Parameters:**
- `x`: X coordinate in logical pixels
- `y`: Y coordinate in logical pixels

**Response:**
```json
{
  "status": "clicked",
  "x": 500,
  "y": 300
}
```

### POST /click-window
**Description:** Perform mouse click on specific window

**Request Body:**
```json
{
  "x": 100,
  "y": 50,
  "cgWindowID": 12345
}
```

**Parameters:**
- `x`: X coordinate relative to window
- `y`: Y coordinate relative to window  
- `cgWindowID`: Core Graphics window ID

**Response:**
```json
{
  "status": "clicked",
  "x": 100,
  "y": 50,
  "cgWindowID": 12345
}
```

---

## Keyboard Control

### POST /key
**Description:** Send keyboard input to desktop

**Request Body:**
```json
{
  "key": "a"
}
```

**Parameters:**
- `key`: Single character or key name (a-z, 0-9, space, etc.)

**Response:**
```json
{
  "status": "key_pressed",
  "key": "a"
}
```

### POST /key-window
**Description:** Send keyboard input to specific window

**Request Body:**
```json
{
  "key": "Enter",
  "cgWindowID": 12345
}
```

**Parameters:**
- `key`: Single character or key name
- `cgWindowID`: Core Graphics window ID

**Response:**
```json
{
  "status": "key_pressed",
  "key": "Enter",
  "cgWindowID": 12345
}
```

---

## Screenshot Utility

### POST /screenshot
**Description:** Take screenshot of specific window using system screencapture

**Request Body:**
```json
{
  "cgWindowID": 12345
}
```

**Response:**
```json
{
  "screenshot": "data:image/jpeg;base64,/9j/4AAQSkZJRgABAQEA...",
  "cgWindowID": 12345
}
```

**Fields:**
- `screenshot`: Base64-encoded JPEG data URL
- `cgWindowID`: Window ID that was captured

---

## CORS Support

All endpoints support CORS with:
- `Access-Control-Allow-Origin: *`
- `Access-Control-Allow-Methods: GET, POST, OPTIONS`
- `Access-Control-Allow-Headers: Content-Type`

### OPTIONS *
**Description:** CORS preflight support for all endpoints

**Response:**
- **Status:** 200 OK
- **Headers:** CORS headers as above

---

## Error Responses

### 400 Bad Request
Invalid JSON or missing required parameters

### 404 Not Found
Endpoint not found

### 500 Internal Server Error
Server-side error (capture failure, permission issues, etc.)

---

## Usage Example

```javascript
// Start desktop capture in high quality
await fetch('/capture', {
  method: 'POST',
  headers: { 'Content-Type': 'application/json' },
  body: JSON.stringify({ type: 0, index: 0, vp9: true })
});

// Get current frame
const response = await fetch('/frame');
const blob = await response.blob();
const imageUrl = URL.createObjectURL(blob);

// Click at coordinates
await fetch('/click', {
  method: 'POST', 
  headers: { 'Content-Type': 'application/json' },
  body: JSON.stringify({ x: 500, y: 300 })
});

// Send key press
await fetch('/key', {
  method: 'POST',
  headers: { 'Content-Type': 'application/json' },
  body: JSON.stringify({ key: 'a' })
});
```

---

## Required Permissions

The server requires the following macOS permissions:
1. **Screen Recording** - System Preferences > Privacy & Security > Screen Recording
2. **Accessibility** - System Preferences > Privacy & Security > Accessibility

Without these permissions, capture and input functionality will not work.