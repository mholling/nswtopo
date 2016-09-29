module NSWTopo
  class TiledMapServer < TiledServer
    def tiles(map, raster_resolution, temp_dir)
      tile_sizes = params["tile_sizes"]
      tile_limit = params["tile_limit"]
      crops = params["crops"] || [ [ 0, 0 ], [ 0, 0 ] ]
      
      cropped_tile_sizes = [ tile_sizes, crops ].transpose.map { |tile_size, crop| tile_size - crop.inject(:+) }
      projection = Projection.new(params["projection"])
      bounds = map.transform_bounds_to(projection)
      extents = bounds.map { |bound| bound.max - bound.min }
      origins = bounds.transpose.first
      
      zoom, resolution, counts = (Math::log2(Math::PI * EARTH_RADIUS / raster_resolution) - 7).ceil.downto(1).map do |zoom|
        resolution = Math::PI * EARTH_RADIUS / 2 ** (zoom + 7)
        counts = [ extents, cropped_tile_sizes ].transpose.map { |extent, tile_size| (extent / resolution / tile_size).ceil }
        [ zoom, resolution, counts ]
      end.find do |zoom, resolution, counts|
        counts.inject(:*) < tile_limit
      end
      
      format, name = params.values_at("format", "name")
      
      counts.map { |count| (0...count).to_a }.inject(:product).map.with_index do |indices, count|
        tile_path = temp_dir + "tile.#{indices.join ?.}.png"
  
        cropped_centre = [ indices, cropped_tile_sizes, origins ].transpose.map do |index, tile_size, origin|
          origin + tile_size * (index + 0.5) * resolution
        end
        centre = [ cropped_centre, crops ].transpose.map { |coord, crop| coord - 0.5 * crop.inject(:-) * resolution }
        bounds = [ indices, cropped_tile_sizes, origins ].transpose.map do |index, tile_size, origin|
          [ origin + index * tile_size * resolution, origin + (index + 1) * tile_size * resolution ]
        end
  
        longitude, latitude = projection.reproject_to_wgs84(centre)
  
        attributes = [ "longitude", "latitude", "zoom", "format", "hsize", "vsize", "name" ]
        values     = [  longitude,   latitude,   zoom,   format,      *tile_sizes,   name  ]
        uri_string = [ attributes, values ].transpose.inject(params["uri"]) do |string, array|
          attribute, value = array
          string.gsub(Regexp.new("\\$\\{#{attribute}\\}"), value.to_s)
        end
        uri = URI.parse(uri_string)
  
        retries_on_blank = params["retries_on_blank"] || 0
        (1 + retries_on_blank).times do
          HTTP.get(uri) do |response|
            tile_path.open("wb") { |file| file << response.body }
            %x[mogrify -quiet -crop #{cropped_tile_sizes.join ?x}+#{crops.first.first}+#{crops.last.last} -type TrueColor -depth 8 -format png -define png:color-type=2 "#{tile_path}"]
          end
          non_blank_fraction = %x[convert "#{tile_path}" -fill white +opaque black -format "%[fx:mean]" info:].to_f
          break if non_blank_fraction > 0.995
        end
        
        $stdout << "\r  (#{count + 1} of #{counts.inject(&:*)} tiles)"
        [ bounds, resolution, tile_path ]
      end.tap { puts }
    end
  end
end
