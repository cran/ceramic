provider_from_type <- function(type) {
  if (grepl("mapbox", type)) return("mapbox")
  if (grepl("elevation-tiles-prod", type)) return("aws")
  NULL
}

guess_format <- function(x) {
  c("png", "jpg")[grepl("satellite", x) + 1L]
}


#' Unpack Mapbox terrain-RGB
#'
#' Mapbox terrain-rgb stores global elevation packed into Byte integers. 
#' 
#' This function unpacks the three layers of a raster to give floating point elevation data. 
#' @param x three layer raster object
#' @param filename optional, filename to store the output
#'
#' @return terra rast object with one numeric layer
#' @export
#'
#' @examples
#' if (interactive() && !is.null(get_api_key())) {
#' unpack_rgb(read_tiles(type = "mapbox.terrain-rgb"))
#' }
unpack_rgb <- function(x, filename = "") {
  if (terra::nlyr(x) < 3) stop("cannot unpack raster with fewer than 3 layers")
  terra::lapp(x[[1:3]], function(.x1, .x2, .x3) -10000 + ((.x1 * 256 * 256 + .x2 * 256 + .x3) * 0.1), filename = filename)
}
#' @name get_tiles
#' @export
read_tiles <- function(x, buffer, type = "mapbox.satellite", crop_to_buffer = TRUE,
                      format = NULL, ..., zoom = NULL, debug = FALSE, max_tiles = NULL, base_url = NULL,
                      verbose = TRUE, filename = "") {
  tiles <- get_tiles(x = x, buffer = buffer, type = type, crop_to_buffer = crop_to_buffer, 
                     format = format, ..., zoom = zoom, debug = debug, max_tiles = max_tiles, base_url = base_url, 
                     verbose = verbose)
  
  ## bit of stuff from ceramic_tiles which we should expose properly
  tile_index <- strsplit(str_extract(tiles$files, "[0-9]+/[0-9]+/[0-9]+"), "/")
  tile_index <- do.call(rbind, lapply(tile_index, as.integer))
  tile_x <- as.numeric(tile_index[,2L, drop = TRUE])
  tile_y <- as.numeric(tile_index[,3L, drop = TRUE])
  zooms <- as.numeric(tile_index[,1L, drop = TRUE])
  
  tile_index <- add_extent(tibble::tibble(tile_x = tile_x, tile_y = tile_y, zoom = zooms, fullname = tiles$files))
  
  mk_rast <- function(row) {
    ex <- terra::ext(row$xmin, row$xmax, row$ymin, row$ymax)
    suppressWarnings(r <- terra::rast(row$fullname))
    set.ext(r, ex)
    set.crs(r, .merc())
    r
  }
  terra::merge(sprc(lapply(split(tile_index, 1:nrow(tile_index)), mk_rast)), filename = filename)
}
#' Download imagery tiles
#'
#' Obtain imagery or elevation tiles by location query. The first argument
#' `loc` may be a spatial object (sp, raster, sf) or a 2-column matrix with a single
#' longitude and latitude value. Use `buffer` to define a width and height to pad
#' around the raw longitude and latitude in metres. If `loc` has an extent, then
#' `buffer` is ignored.
#'
#' `get_tiles()` may be run with no arguments, and will download (and report on) the default
#' tile source at zoom 0. Arguments `type`, `zoom` (or `max_tiles`), `format` may be used
#' without setting `loc` or `buffer` and the entire world extent will be used. Please use with caution!
#' There is no maximum on what will be downloaded, but it can be interrupted at any time.
#'
#' Use `debug = TRUE` to avoid download and simply report on what would be done.
#'
#' Available types are 'elevation-tiles-prod' for AWS elevation tiles, and 'mapbox.satellite',
#' 'mapbox.terrain-rgb'.  (The RGB terrain values are not unpacked.)
#'
#' Function `read_tiles()` will match what `get_tiles()` does and actually build a raster object. 
#'
#' @param x a longitude, latitude pair of coordinates, or a spatial object
#' @param buffer width in metres to extend around the location, ignored if 'x' is a spatial object with extent
#' @param type character string of provider imagery type (see Details)
#' @param crop_to_buffer crop to the user extent, used for creation of output objects (otherwise is padded tile extent)
#' @param format tile format to use, defaults to "jpg" for Mapbox satellite imagery and "png" otherwise
#' @param ... arguments passed to internal function, specifically `base_url` (see Details)
#' @param zoom desired zoom for tiles, use with caution - if `NULL` is chosen automatically
#' @param debug optionally avoid actual download, but print out what would be downloaded in non-debug mode
#' @param max_tiles maximum number of tiles - if `NULL` is set by zoom constraints
#' @param base_url tile provider URL expert use only
#' @param verbose report messages or suppress them
#' @param filename purely for [read_tiles()] this is passed down to the the terra package function 'merge'
#' @export
#' @return A list with files downloaded in character vector, a data frame of the tile indices,
#' the zoom level used and the extent in xmin,xmax,ymin,ymax form.
#' @name get_tiles
#' @seealso get_tiles_zoom get_tiles_dim get_tiles_buffer 
#' @examples
#' if (!is.null(get_api_key())) {
#'    tile_info <- get_tiles(ext(146, 147, -43, -42), type = "mapbox.satellite", zoom = 5)
#' }
get_tiles <- function(x, buffer, type = "mapbox.satellite", crop_to_buffer = TRUE,
                      format = NULL, ..., zoom = NULL, debug = FALSE, max_tiles = NULL, base_url = NULL,
                      verbose = TRUE) {
  if (missing(x) && missing(buffer)) {
    ## get the whole world at zoom provided, as a neat default
    x <- cbind(0, 0)
    buffer <- c(20037508, 20037508)
    if (is.null(zoom) && is.null(max_tiles)) {
      zoom <- 0
    }
  }
  if (is.null(format)) {
    format <- guess_format(type)
  }
  if (!is.null(zoom)) max_tiles <- NULL
  if (!is.null(base_url)) {
    ## zap the type because input was a custom mapbox style (we assume)
    type <- ""
  }

  bbox_pair <- spatial_bbox(x, buffer)

  my_bbox <- bbox_pair$tile_bbox
  bb_points <- bbox_pair$user_points
 if (is.null(zoom) && is.null(max_tiles)) {
      max_tiles <- 32
    }

  tile_grid <- slippymath::bbox_to_tile_grid(my_bbox, max_tiles = max_tiles, zoom = zoom)
  zoom <- tile_grid$zoom

  if (is.null(base_url)) {
    provider <- provider_from_type(type)
    if (is.null(provider)) stop(sprintf("Provider for '%s' not known", type))
    query_string <- switch(provider,
                           mapbox = mapbox_string(type = type, format = format),
                           aws = aws_string())
  } else {  ## handle custom
    query_string <- mk_query_string_custom(baseurl = base_url)
  }

#print(query_string)
  files <- unlist(down_loader(tile_grid, query_string, debug = debug, verbose = verbose))
  bad <- file.info(files)$size < 35

  if (!debug && all(bad)) {
    mess <-paste(files, collapse = "\n")
    stop(sprintf("no sensible tiles found, check cache?\n%s", mess))
  }
  user_ex <- NULL
  if (crop_to_buffer) user_ex <- as.vector(bb_points)
  out <- list(files = files[!bad], tiles = tile_grid, extent = user_ex)
  if (debug) {
    out <- invisible(out)
  }

  out
}

#' Get tiles with specific constraints
#'
#' Get tiles by zoom, by overall dimension, or by buffer on a single point.
#'
#'  Each function expects an extent in longitude latitude or a spatial object with extent as the first argument.
#'
#' `get_tiles_zoom()` requires a zoom value, defaulting to 0
#'
#' `get_tiles_dim()` requires a dim value, default to `c(512, 512)`, a set of 4 tiles
#'
#' `get_tiles_buffer()` requires a single location (longitude, latitude) and a buffer in metres
#' @param x a spatial object with an extent
#' @param ... passed to `get_tiles()`
#' @param dim for `get_tiles_dim` the overall maximum dimensions of the image (padded out to tile size of 256x256)
#' @param zoom desired zoom for tiles, use with caution - cannot be unset in `get_tiles_zoom`
#' @param buffer width in metres to extend around the location, ignored if 'x' is a spatial object with extent
#' @param max_tiles maximum number of tiles - if `NULL` is set by zoom constraints
#' @param format defaults to "png", also available is "jpg"
#' @name get-tiles-constrained
#' @aliases get_tiles_zoom get_tiles_dim get_tiles_buffer
#' @return A list with files downloaded in character vector, a data frame of the tile indices,
#' the zoom level used and the extent in xmin,xmax,ymin,ymax form.
#' @export
#' @seealso get_tiles
#' @examples
#' if (!is.null(get_api_key())) {
#'  ex <- ext(146, 147, -43, -42)
#'  tile_infoz <- get_tiles_zoom(ex,  zoom = 1)
#'
#'  tile_infod <- get_tiles_dim(ex,  dim = c(256, 256))
#'
#'  tile_infob <- get_tiles_buffer(cbind(146.5, -42.5), buffer = 5000)
#' }
get_tiles_zoom <- function(x, zoom = 0, ..., format = "png") {
  if ("max_tiles" %in% names(list(...))) {
    stop("max_tiles cannot be set by 'get_tiles_zoom()', use 'get_tiles_dim()'")
  }
  get_tiles(x, zoom = zoom, ..., format = format)
}
#' @export
#' @name get-tiles-constrained
get_tiles_dim <- function(x, dim = c(512, 512), ..., format = "png") {
  max_tiles <- prod(ceiling(dim / c(256, 256)))
  if ("zoom" %in% names(list(...))) {
    stop("zoom cannot be set by 'get_tiles_dim()', use 'get_tiles_zoom()'")
  }
  get_tiles(x, max_tiles = max_tiles, ..., format = format)
}
#' @export
#' @name get-tiles-constrained
get_tiles_buffer <- function(x, buffer = NULL, ..., max_tiles = 9, format = "png") {
  if (is.null(buffer)) {
    stop("buffer cannot be NULL in 'get_tiles_buffer()'")
  }
  if (!is.numeric(x) || !length(x) == 2L) {
    stop("get_tiles_buffer() expects a single point location longitude,latitude")
  }
  get_tiles(x, buffer = buffer, max_tiles = max_tiles, ..., format = format)
}


