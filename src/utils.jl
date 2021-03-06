using StatsBase
using StatsBase: shuffle
using Flux, Flux.Tracker, Flux.Optimise
using Flux.Tracker: @grad
using Base.Iterators
using Statistics
include("crop_and_resize_new.jl")
include("nms.jl")
include("load_weights.jl")

function compute_iou(box, boxes, box_area, boxes_area)
	y1 = max.(box[1], boxes[:,1])
	y2 = min.(box[3], boxes[:,3])
	x1 = max.(box[2], boxes[:,2])
	x2 = min.(box[4], boxes[:,4])
	intersection = max.(x2 .- x1, 0) .* max.(y2 .- y1, 0)
    union = box_area .+ boxes_area .- intersection
    iou = intersection ./ union
    iou
end

function compute_overlaps(boxes1, boxes2)
	areas1 = (boxes1[:,3] .- boxes1[:,1]) .* (boxes1[:, 4] .- boxes1[:, 2]) 
	areas2 = (boxes2[:,3] .- boxes2[:,2]) .* (boxes2[:, 4] .- boxes2[:, 2]) 

	overlaps = zeros(size(boxes1,1), size(boxes2,1))
	for i = 1:size(overlaps, 2)
		box2 = boxes2[i,:]
		overlaps[:,i] = compute_iou(box2, boxes1, areas2[i], areas1)
	end
	overlaps
end

"""
	gt_box = box = rand(10, 4)
"""
function box_refinement(box, gt_box)
	# @show box
	# @show gt_box
	# box = Float32.(box)
	# gt_box = Float32.(gt_box)
	height = box[:, 3] .- box[:, 1]
	width = box[:, 4] .- box[:, 2]
	# width = replace(x -> x < 1f-3 ? 1.f0 : x, width)
	# height = replace(x -> x < 1f-3 ? 1.f0 : x, height)
	width = clamp.(width, 1f-3, 1.f0) # remove
	height = clamp.(height, 1f-3, 1.f0) # remove
	center_y = box[:, 1] .+ 0.5f0 .* height
	center_x = box[:, 2] .+ 0.5f0 .* width
	# return center_x
	gt_height = gt_box[:, 3] .- gt_box[:, 1]
	gt_width = gt_box[:, 4] .- gt_box[:, 2]
	gt_center_y = gt_box[:, 1] .+ 0.5f0 .* gt_height
	gt_center_x = gt_box[:, 2] .+ 0.5f0 .* gt_width

	dy = (gt_center_y .- center_y) ./ height
	dx = (gt_center_x .- center_x) ./ width
	# return dy
	dh = log.(gt_height ./ height)
	dw = log.(gt_width ./ width)
	@show gt_center_x .- center_x
	@show width

	# for (i,ff) in enumerate([gt_height, gt_width, height, width, center_x, center_y, gt_center_x, gt_center_y, dy, dx, dh, dw])
	# 	if length(findall(isinf, ff)) > 0
	# 		error("infs in $i")
	# 	end
	# end	

	hcat(dy, dx, dh, dw)
end

# Images.jl and Interpolations cannot track types properly
# Tracker.track()
# import Images.imresize
# import Images.ImageTransformations.imresize!
# import Images.ImageTransformations.imresize_type
# # imresize!(dest::AbstractArray, original::Tracker.TrackedArray) = Tracker.track(imresize!, dest), original)
# imresize(original::TrackedArray, new_size::Dims; kw...) = Tracker.track(imresize, original, new_size; kw...)
# Images.ImageTransformations.Interpolations.tcoef(A::TrackedArray) = eltype(A)

# crop as img[y1:y2, x1:x2, :]

function resize_image(img, min_dim = false, max_dim = false, padding = false)
	h, w = size(img)[1:2]
	window = (0.,0.,h,w)
	scale = 1.f0

	if min_dim > 0
		scale = max(1, min_dim / min(h, w))
	end

	if max_dim > 0
		image_max = max(h, w)
		if round(image_max * scale) > max_dim
			scale = max_dim / image_max
		end
	end

	if scale != 1.
		img = imresize(img, (round(Int, h*scale), round(Int, w*scale), 3))
	end

	resized_img = zeros(max_dim, max_dim, 3)
	h, w = size(img)[1:2]
	top_pad = max(1, round(Int, (max_dim - h) / 2))
    bottom_pad = max_dim - h - top_pad
    left_pad = max(1, round(Int, (max_dim - w) / 2))
    right_pad = max_dim - w - left_pad
    resized_img[top_pad:(h+top_pad-1), left_pad:(w+left_pad-1), 1:3] .= img
    padding = [(top_pad, bottom_pad), (left_pad, right_pad), (0, 0)]
    window = (top_pad, left_pad, h + top_pad, w + left_pad)
    resized_img, window, scale, padding
end


# mask is the shape of an image wtf
# mask = rand(28,28, 10) => 10 masks of size 28 x 28 (to be applied to every channel)
function extract_bboxes(mask)
	nth = last(size(mask))
	boxes = zeros(Integer, nth, 4)
	for i =1:nth
		m = mask[:,:,i]
		cluster = findall(!iszero, m)
		if length(cluster) > 0	
			Is = map(x -> [x.I[1], x.I[2]], cluster) |> x -> hcat(x...)'
			x1, x2 = extrema(Is[:,1])
			y1, y2 = extrema(Is[:,2])
		else
			x1 ,x2, y1, y2 = 0, 0, 0, 0
		end

		boxes[i,:] = [y1, x1, y2, x2]
	end
	boxes
end

function upsample(x, scale_factor::Tuple)
  repeat(x, inner = scale_factor)
end

function bbox_overlaps(boxes1, boxes2)
	max_boxes = max.(boxes1, boxes2)
	zs = similar(boxes1[:,1])
	zs .= 0.f0
	intersection = max.(max_boxes[:,4] .- max_boxes[:,2], zs) .* max.(max_boxes[:,3] .- max_boxes[:,1], zs)
	b1_areas = (boxes1[:,3] .- boxes1[:,1]) .* (boxes1[:,4] .- boxes1[:,2])
	b2_areas = (boxes2[:,3] .- boxes2[:,1]) .* (boxes2[:,4] .- boxes2[:,2])

	unions = (b1_areas .+ b2_areas) .- intersection

	iou = intersection / unions
	iou
end

function myexp(arr)
	[exp(x) for x in arr]
end

function apply_box_deltas(boxes, deltas)
  @show boxes[1,:]
  @show deltas[1,:]
  @show findall(isnan, boxes)
  @show findall(isnan, deltas)
  @show typeof(deltas)
  # error("nans")
  # bs = copy(boxes)

  heights = boxes[:,3] .- boxes[:,1]
  widths = boxes[:,4] .- boxes[:,2]
  centers_y = boxes[:,1] .+ (0.5f0 .* heights)
  centers_x = boxes[:,2] .+ (0.5f0 .* widths)


  centers_y = centers_y .+ (deltas[:,1] .* heights)
  centers_x = centers_x .+ (deltas[:,2] .* widths)
  # hs = deepcopy(heights)
  # @show findall(x -> isinf(x) || isnan(x), deltas[:,3])
  # @show findall(x -> isinf(x) || isnan(x), deltas[:,4])
  # @show findall(x -> isinf(x) || isnan(x), heights)
  # @show findall(x -> isinf(x) || isnan(x), widths)
  # @show findall(x -> isinf(x) || isnan(x), centers_x)
  # @show findall(x -> isinf(x) || isnan(x), centers_y)

  # @show maximum(deltas[:,3])
  # @show maximum(deltas[:,4])
  # @show maximum(heights)
  # @show maximum(widths)
  # @show maximum(centers_x)
  # @show maximum(centers_y)
  # @show std(deltas[:,3])
  # @show std(deltas[:,4])
  
  heights = heights .* exp.(deltas[:,3])
  widths = widths .* exp.(deltas[:,4])
  # global gh = heights
  # global gw = widths
  # error()

  infinds = findall(x -> isinf(x) || isnan(x), heights)
  @show deltas[:,3][infinds]
  @warn "something"
  # @show hs[findall(x -> isinf(x) || isnan(x), heights)]
  @show exp.(deltas[:,3])[findall(x -> isinf(x) || isnan(x), heights)]
  # @show findall(x -> isinf(x) || isnan(x), widths)

  # t = findall(isinf, heights)
  # v = findall(isinf, deltas[:,3])
  # @show v
  # # push!(t, 1)
  # @show exp.(deltas[:,3])[t]
  # @show hs[t]
  # @show hs[t] .* exp.(deltas[t,3])
  # p = findall(isinf, heights)
  # @show all(v.==p)
  # heights = replace(x -> isinf(x) ? 0.0f0 : x, heights)
  # widths = replace(x -> isinf(x) ? 0.0f0 : x, widths)
  y1s = centers_y .- (0.50f0 .* heights)
  x1s = centers_x .- (0.5f0 .* widths)
  y2s = y1s .+ heights
  x2s = x1s .+ widths
  Flux.stack([y1s, x1s, y2s, x2s], 2)
  # m = hcat(y1s, x1s, y2s, x2s)
  # ff = findall(isinf, heights)
  # if length(ff) > 0
  # 	@show size(y1s)
  # 	@show size(y2s)
  # 	t = findall(isinf, heights)
  # 	@show y1s[t]
  # 	@show heights[t]
  # 	@warn "nans in s"
  # 	@show "!!!!!!!!!!!!!!!"
  # end
  
end

# function clip_boxes(boxes, window)
#   y1 = max.(min.(boxes[:,1], window[:,3]), window[:,1])
#   x1 = max.(min.(boxes[:,2], window[:,4]), window[:,2])
#   y2 = max.(min.(boxes[:,3], window[:,3]), window[:,1])
#   x2 = max.(min.(boxes[:,4], window[:,4]), window[:,2])
#   hcat(y1,x1,y2,x2)
# end

function clip_boxes(boxes, window)
  y1 = clamp.(boxes[:,1], window[1], window[3])
  x1 = clamp.(boxes[:,2], window[2], window[4])
  y2 = clamp.(boxes[:,3], window[1], window[3])
  x2 = clamp.(boxes[:,4], window[2], window[4])
  hcat(y1,x1,y2,x2)
end

"""
	generate all the boxes that need to be refined and chosen and set
	scales = rand(n)
	ratios = rand(m)
	shape = (28,28)
	feature_stride = 0.2 # stride compared to the image to align the features with the image
	anchor_stride = 2 # generate an anchor every `2` steps

	pytorch expected [... ...
					  ... ...]
	the input shape remains this one ^

	but we operate on it transposed [. .
									 . .

									 . .
									 . .]


    For reference:
	xx, yy = np.meshgrid(l1, l2)
	xx == collect(flatten(l1'))' .* ones(length(l1), length(l2)))
	yy == collect(flatten(l2)) .* ones(length(l1), length(l2)))

	could also use `repeat`, but would allocate off the butt

	use `broadcasting` here

	xx == repeat(l1', length(l2))
"""
function generate_anchors(scales, ratios, shape, feature_stride, anchor_stride)
   ls, lr = length(scales), length(ratios)
   sr = size(ratios)

   scales = collect(flatten(scales'))
   ratios = sqrt.(flatten(ratios'))

   heights = collect(flatten(scales / ratios))
   widths = collect(flatten(scales * ratios'))
   lw, lh = length(widths), length(heights)

   shifts_y = collect((0:anchor_stride:shape[1]) .* feature_stride)[1:end-1]
   shifts_x = collect((0:anchor_stride:shape[2]) .* feature_stride)[1:end-1]
   ly = length(shifts_y)
   lx = length(shifts_x)

   shifts_x = repeat(collect(shifts_x), ly)    #|> x -> reshape(x, ly,ly)
   shifts_y = repeat(collect(shifts_y), lx)  #|> x -> reshape(x, lx,lx)

   box_widths = repeat(widths', length(shifts_x))
   box_centers_x = repeat(shifts_x, 1, lw) # |> x -> reshape(x, length(widths), length(shifts_x))
   # @show lw, lh
   box_heights = repeat(heights', length(shifts_y))
   box_centers_y = repeat(shifts_y[1:ly], inner = (ly, lh)) # |> x -> reshape(x, length(widths), length(shifts_x))

   box_centers = Flux.stack([box_centers_y, box_centers_x], 3)
   global gbc = box_centers
   box_centers = permutedims(box_centers, (2,1,3)) |> x -> reshape(x, :, 2)

   box_sizes = Flux.stack([box_heights, box_widths], 3)
   global gbs = box_sizes
   box_sizes = permutedims(box_sizes, (2,1,3)) |> x -> reshape(x, :, 2)

   cat(box_centers .- (0.5f0 .* box_sizes), box_centers .+ (0.5f0 .* box_sizes), dims = 2)
   # return box_centers
end

function generate_anchors2(scales, ratios, shape, feature_stride, anchor_stride)
	ls = length(scales)
	lr = length(ratios)
	s = repeat(scales, lr)
	r = repeat(ratios, inner = ls)
	h = s ./ sqrt.(r)
	w = s .* sqrt.(r)

	shifts_y = collect((0:anchor_stride:shape[1]) * feature_stride)[1:end-1]
	shifts_x = collect((0:anchor_stride:shape[2]) * feature_stride)[1:end-1]

	lx = length(shifts_x)
	ly = length(shifts_y)
	shifts_x = repeat(shifts_x', ly)
	shifts_y = repeat(shifts_y, outer = (1,lx))

	lsx = length(shifts_x)
	lsy = length(shifts_y)
	lw = length(w)
	lh = length(h)
	box_widths = repeat(w', lsx)
	box_centers_x = repeat(shifts_x[1,:], outer = (size(shifts_x, 1),lw))
	
	box_heights = repeat(h', lsy)
	box_centers_y = repeat(shifts_y[:,1], inner = (size(shifts_y, 1),lh))

	box_centers = Flux.stack([box_centers_y, box_centers_x], 3)

	Flux.stack([box_centers_y, box_centers_x], 3)
end



function generate_pyramid_anchors(scales, ratios, feature_shapes, 
								feature_strides, anchor_stride)
	anchors = []
	# scales = transpose(scales)
	for i = 1:size(scales, 1)
		push!(anchors, generate_anchors(scales[i,:], ratios, feature_shapes[i,:],
										feature_strides[i], anchor_stride))
	end

	gpu(cat(anchors..., dims = 1))
end

"""
	inputs => (boxes, feature_maps...)
	boxes => rand(10,4) (TODO: => rand(4,10,10)
	feature_maps = similar(batch)
	batch => rand(299, 299, 3, 10)
	pool_size => [7,7]
"""
function pyramid_roi_align(inputs, pool_size, image_shape)
	boxes = inputs[1]
	feature_maps = inputs[2:end]
	@show size(boxes)
	@show typeof(feature_maps)
	# @show findall(x -> isnan(x) || isinf(x), boxes)
	for f in feature_maps
		@show size(f), typeof(f)
	end
	@warn "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"

	h = boxes[:,3] .- boxes[:,1]
	w = boxes[:,4] .- boxes[:,2]
	# @show boxes
	# @show findall(x -> isinf(x) || isnan(x), h)
	# @show findall(x -> isinf(x) || isnan(x), w) # error on nans here or remove nan cases
	# @show w
	# @show findall(iszero, h)
	image_area = prod(image_shape[1:2])
	@show typeof(h), typeof(w)
	roi_level = 4.0f0 .+ log2.( sqrt.(h.*w) ./ (224.0f0/sqrt(image_area) ))
	@show roi_level |> typeof
	# roi_level_data = map(x -> isnan(x) || isinf(x) ? 0.0f0 : x, roi_level) # remove
	roi_level = round.(roi_level)
	@show roi_level
	roi_level = clamp.(roi_level, 2,5)
	# @show roi_level

	pooled = []
	box_to_level = []
	for (i,level) in enumerate(2:5)
		
		ix = level .== roi_level
		@show level
		!any(ix) && continue
		global gboxes = boxes
		level_boxes = boxes'[:, ix]'
		@show sum(ix)
		push!(box_to_level, findall(ix))

		# don't track further
		global glevel = level_boxes

		# FIXME: `ind` should correlate bounding box to index of image
		# boxes => [. . . .    boxes_ind => [1 1 2] => first two bounding boxes belong
		#           . . . .                            to the first image, the third one
		#           . . . .]                           to the second image

		ind = ones(Integer, size(level_boxes)[1]) # always ones since batch size is assumed one
		# @show level_boxes
		# @show ind
		# @show pool_size
		@show size(feature_maps[i])
        # @show level_boxes
        @show size(level_boxes)
        # @show ind
        @show size(ind)

        # global gfeature_maps = feature_maps
        # global glevel_boxes = level_boxes
        # global gind = ind
        # global gpool_size = pool_size
        # error()

        # @show @which crop_and_resize(feature_maps[i], level_boxes, ind, pool_size, pool_size)
        @show typeof(feature_maps[i])

		pooled_features = crop_and_resize(feature_maps[i], level_boxes, ind; crop_height = pool_size, crop_width = pool_size, extrapolation_value = 0.f0)
		@show typeof(pooled_features)
		@show size(pooled_features)
		@warn "*******************"
		# for f in pooled_features
		# 	@show size(f)
		# end
		push!(pooled, pooled_features)

	end
	@show size(pooled[1])
	@show typeof(pooled[1])
	# for p in pooled
	# 	for v in p
	# 		@show  size(v)
	# 	end
	# end
	pooled = cat(pooled..., dims = 4) |> gpu
        @show typeof(pooled)
	box_to_level = reduce(vcat, box_to_level)

	# inds = sortperm(box_to_level)
	sinds = 1:size(pooled, ndims(pooled))
	@show size(pooled)
	# pooled = selectdim(pooled, ndims(pooled), sinds)
	# pooled = [:, :, :, sinds]
	pooled
end

"""
	inputs => (rand(2,10), rand(4,10))
				^			
				foreground/ background score
							^
							box deltas

	config.RPN_BBOX_STD_DEV = [0.1 0.1 0.2 0.2]
	config.IMAGE_SHAPE = [1024, 1024, 3]
"""
function proposal_layer(rpn_class_slice, rpn_bbox_slice; proposal_count = 2000, nms_threshold = 0.7f0, anchors, config=Nothing)
	# rpn_class_slice = inputs[1]
	# rpn_bbox_slice = inputs[2]
	# return rpn_class_slice, rpn_bbox_slice .* 8.0f0
	scores = rpn_class_slice[:,2]
	# @show typeof(inputs[1])
	# @show typeof(inputs[2])
	
	deltas = rpn_bbox_slice
	@show typeof(deltas)
	RPN_BBOX_STD_DEV = [0.1f0 0.1f0 0.2f0 0.2f0] |> gpu
	IMAGE_SHAPE = (1024, 1024, 3)

	# 
	deltas = deltas .* RPN_BBOX_STD_DEV
	global pldeltas = deltas
	# return scores, deltas
	pre_nms_limit = min(6000, size(anchors, 1))# ndims(anchors))) # min -> minimum
	# scores, order = sort(scores, rev = true), sortperm(scores, rev = true)
	# return scores, deltas
	# Breaks Flux AF
	# sorting is inefficient on the GPU
	s = cpu(copy(scores))
	order = sortperm(s, rev = true)
	# scores = scores[order]
	order = order[1:pre_nms_limit]
	# scores = map(x -> x + zero(x), scores)
	scores = scores[order]
	# deltas = map(x -> x + zero(x), deltas)
	deltas = deltas[order, :]
	anchors = anchors[order, :]
	# return scores, deltas
	@show mean(deltas)
	@show maximum(deltas)
	# global gdeltas = deltas
	boxes = apply_box_deltas(anchors, deltas)
	height, width = IMAGE_SHAPE[1:2]
	window = [0.0f0 0.0f0 height width] |> gpu
	@show typeof(boxes)
	boxes = clip_boxes(boxes, window)

	# need nms here
	imp = hcat(boxes, scores)
	@show size(boxes)
	# @show 
	# return imp
	@show "now for nms"
	@show imp[1,:]
	keep = nms2(imp, nms_threshold)
	@show "keep"
	# @show keep
	# @show boxes[keep,:]
	if proposal_count < length(keep)
		keep = keep[1:proposal_count]
	end
	normaliser = [height width height width] |> gpu
	normalised_boxes = boxes[keep,:] ./ normaliser
	@show size(normalised_boxes)


	# remove
	# Remove NaNs
	# nanrows = Int[]
	# for (i,row) in enumerate(eachrow(normalised_boxes))
	# 	if NaN in row
	# 		push!(nanrows, i)
	# 	end
	# end
	# nonnanrows = setdiff(1:size(normalised_boxes, 1), nanrows)
	##########################
	@show typeof(normalised_boxes)

	nb = copy(normalised_boxes) |> cpu
	h = .!isapprox.(nb[:, 3] .- nb[:, 1], 0.f0, atol = 1f-2)
	w = .!isapprox.(nb[:, 4] .- nb[:, 2], 0.f0, atol = 1f-2)
	idx = findall(h .| w)
	normalised_boxes = normalised_boxes[idx, :]
	normalised_boxes
	# error()
end

function bbox_overlaps2(boxes1, boxes2)
    boxes1_repeat = (size(boxes2, 1), 1, 1)
    boxes2_repeat = (size(boxes1, 1), 1, 1)
    boxes1 = repeat(boxes1, outer = boxes1_repeat)
    boxes2 = repeat(boxes2, outer = boxes2_repeat)
    b1_y1, b2_y1 = boxes1[:, 1], boxes2[:, 1]
    b1_x1, b2_x1 = boxes1[:, 2], boxes2[:, 2]
    b1_y2, b2_y2 = boxes1[:, 3], boxes2[:, 3]
    b1_x2, b2_x2 = boxes1[:, 4], boxes2[:, 4]
    y1 = max.(b1_y1, b2_y1)
    x1 = max.(b1_x1, b2_x1)
    y2 = min.(b1_y2, b2_y2)
    x2 = min.(b1_x2, b2_x2)
    zs = zeros(size(y1, 1)) |> gpu
    intersection = max.(x2 .- x1 .+ 1, zs) .* max.(y2 .- y1 .+ 1, zs)
    b1_area = (b1_y2 .- b1_y1 .+ 1) .* (b1_x2 .- b1_x1 .+ 1)
    b2_area = (b2_y2 .- b2_y1 .+ 1) .* (b2_x2 .- b2_x1 .+ 1)
    unions = b1_area .+ b2_area .- intersection
    iou = intersection ./ unions
    iou = reshape(iou, boxes2_repeat[1], boxes1_repeat[1])
    iou
end

function detection_target_layer(proposals, gt_class_ids, gt_boxes, gt_masks, config = Nothing)
	# IMAGE_SHAPE = (1024, 1024, 3)
	# multiplier = [IMAGE_SHAPE[1] IMAGE_SHAPE[2] IMAGE_SHAPE[1] IMAGE_SHAPE[2]] |> gpu
	# proposals = proposals .* multiplier
	# return proposals
	condition = gt_class_ids .< 0
	if any(findall(condition))
		crowd_ix = findall(x -> x < 0, gt_class_ids)
		non_crowd_ix = findall(x -> x > 0, gt_class_ids)
		crowd_boxes = gt_boxes[crowd_ix, :]
		crowd_masks = gt_masks[crowd_ix, :, :]
		gt_class_ids = gt_class_ids[non_crowd_ix]
		gt_boxes = gt_boxes[non_crowd_ix, :]
        gt_masks = gt_masks[:, :, non_crowd_ix]

        crowd_overlaps = bbox_overlaps2(proposals, crowd_boxes)
        crowd_iou_max = maximum(crowd_overlaps, dims = 2)
        no_crowd_bool = crowd_iou_max .< 0.001f0

    else
	@show "extra"
    	no_crowd_bool = trues(size(proposals, 1))
    end

    @show "beofre first op"
    @show size(proposals)
    @show size(gt_boxes)
    @show typeof(proposals)
    @show typeof(gt_boxes)
    overlaps = bbox_overlaps2(proposals, gt_boxes)
    @show overlaps |> size
    @show "after first op"
    roi_iou_max = maximum(overlaps, dims = 2)
    # return overlaps
    positive_roi_bool = roi_iou_max .>= 0.3f0
    # return roi_iou_max

    if sum(positive_roi_bool) > 0
    	positive_indices = findall(positive_roi_bool)
    	@show length(positive_indices)
	@show typeof(positive_indices)

    	# Filter out tiny boxes
    	# p = proposals[positive_indices, :]
    	# height = p[:,4] .- p[:,2]
    	# width = p[:,3] .- p[:,1]
    	# fh1 = findall(iszero, height)
    	# fw1 = findall(iszero, width)
    	# ff = union(fh1, fw1)
    	# h = setdiff(1:size(p, 1), ff)
    	# proposals = proposals[h,:]

    	# Aim for 33% of the population to have some sensible bbox
    	TRAIN_ROIS_PER_IMAGE = 200
    	ROI_POSITIVE_RATIO = 0.33f0
    	positive_count = min(length(positive_indices),
		round(Int32, TRAIN_ROIS_PER_IMAGE * ROI_POSITIVE_RATIO))
	# positive_count = round(Int32, TRAIN_ROIS_PER_IMAGE * ROI_POSITIVE_RATIO)
    	rand_idx = shuffle(positive_indices)
    	rand_idx = rand_idx[1:positive_count]
    	@show length(rand_idx)
    	# @show positive_indices
    	# @show positive_indices[rand_idx[1]]

    	# positive_indices = positive_indices[rand_idx]
    	positive_indices = rand_idx
    	@show typeof(positive_indices)
    	positive_count = size(positive_indices, 1)
    	positive_indices = map(x -> x.I[1], positive_indices)
    	positive_rois = proposals[positive_indices, :]
	@show size(positive_rois)
	# return positive_rois

	positive_indices = Int.(positive_indices)
    	positive_overlaps = overlaps[positive_indices, :]
	# return positive_overlaps
	global gpositive_overlaps = positive_overlaps
	# gradients dropped here
    	# roi_gt_box_assignment = findmax(positive_overlaps.data, dims = 2)[2]
	# @show roi_gt_box_assignment
	# @show typeof(roi_gt_box_assignment)
    	# roi_gt_box_assignment = vec(map(x -> x.I[2], roi_gt_box_assignment))
	roi_gt_box_assignment = map(argmax, eachrow(positive_overlaps))
    	roi_gt_boxes = gt_boxes[roi_gt_box_assignment, :]
    	# @show size(roi_gt_boxes)
    	roi_gt_class_ids = gt_class_ids[roi_gt_box_assignment]

    	# no infs in positive_rois or roi_gt_boxes
    	# infs in deltas
    	@show typeof(positive_rois)
    	@show typeof(roi_gt_boxes)
	# return positive_rois
    	deltas = box_refinement(positive_rois, roi_gt_boxes)
	# return deltas
    	@show typeof(deltas)
    	BBOX_STD_DEV = [0.1f0 0.1f0 0.2f0 0.2f0] |> gpu
    	std_dev = BBOX_STD_DEV

    	deltas = deltas ./ std_dev
    	# ff = findall(isinf, deltas)
    	# if length(ff) > 0
    	# 	error("infs in deltas")
    	# end
    	roi_masks = gt_masks[:,:, roi_gt_box_assignment]

    	boxes = positive_rois
	@show size(boxes)
	@show size(roi_masks)
	@show size(roi_gt_boxes)
	# return boxes
    	USE_RPN_ROIS = true
    	if USE_RPN_ROIS
    		y1 = boxes[:, 1]
    		x1 = boxes[:, 2]
    		y2 = boxes[:, 3]
    		x2 = boxes[:, 4]

    		gt_y1 = roi_gt_boxes[:, 1]
    		gt_x1 = roi_gt_boxes[:, 2]
    		gt_y2 = roi_gt_boxes[:, 3]
    		gt_x2 = roi_gt_boxes[:, 4]

    		gt_h = gt_y2 .- gt_y1
    		gt_w = gt_x2 .- gt_x1
    		# @show gt_h

    		y1 = (y1 .- gt_y1) ./ gt_h
            x1 = (x1 .- gt_x1) ./ gt_w
            y2 = (y2 .- gt_y1) ./ gt_h
            x2 = (x2 .- gt_x1) ./ gt_w
	    # return y1, x1, y2, x2
            tboxes = hcat(y1, x1, y2, x2)
	    # return tboxes
	    @show size(tboxes)
	    @show typeof(y1), typeof(x1), typeof(y2), typeof(x2) 
            @show length(y1), length(x1), length(y2), length(x2)
	    @info "inside the block"
        end
	# return tboxes
        box_ids = collect(1:size(roi_masks, ndims(roi_masks)))

		# crop_and_resize(feature_maps, level_boxes, ind, pool_size)
		MASK_SHAPE = (28, 28)
		# @info "before crop_and_resize"
		# @show size(roi_masks)
		roi_masks = reshape(roi_masks, (size(roi_masks)..., 1))
		# return boxes, roi_masks
		# @show boxes
		@show size(roi_masks)
		# roi_masks = dropdims(roi_masks, dims = 3)
		roi_masks = permutedims(roi_masks, (1,2,4,3))
		@show size(roi_masks)
		@show typeof(roi_masks)
		@show typeof(tboxes)

		@show size(tboxes)
		global groi_masks = roi_masks
		global gboxes_kill_me = tboxes
		global gbox_ids = box_ids
		@show MASK_SHAPE
			
		# error()
		masks = crop_and_resize(roi_masks, tboxes, box_ids; crop_height = MASK_SHAPE[1], crop_width = MASK_SHAPE[2], extrapolation_value = 0.f0)
		# return masks
		# @show size(masks)
		# masks = permutedims(masks, (1,2,4,3))
		masks = dropdims(masks, dims = 3)
		# @info "after crop_and_resize"
		# @show size(masks)
		# masks = round.(masks)
		# return masks
	else
		positive_count = 0
	end

	negative_roi_bool = roi_iou_max .< 0.5
        # @show typeof(negative_roi_bool)
        # @show typeof(no_crowd_bool)
	negative_roi_bool = cpu(copy(negative_roi_bool)) .& no_crowd_bool
	# @info "here"
	# @show findall(!iszero, vec(negative_roi_bool))
	@show sum(findall(!iszero, vec(negative_roi_bool)))
	if sum(findall(!iszero, vec(negative_roi_bool))) > 0 && (positive_count > 0)
		negative_indices = findall(!iszero, negative_roi_bool)
		ROI_POSITIVE_RATIO = 0.33f0
		r = 1.0f0 / ROI_POSITIVE_RATIO
		negative_count = min(length(negative_indices), floor(Integer, (r - 1) * positive_count))
		rand_idx = shuffle(1:size(negative_indices, 1))
		rand_idx = rand_idx[1:negative_count]
		negative_indices = negative_indices[rand_idx]
		negative_count = size(negative_indices, ndims(negative_indices))
		# @show size(proposals)
		negative_indices = map(x -> x.I[1], negative_indices)
		negative_rois = @view proposals[negative_indices, :]
		# @show size(negative_rois)
		# return negative_rois	
	else
		negative_count = 0
	end
	@show positive_count, negative_count
	# error()
	if positive_count > 0 && negative_count > 0
		@info "my counts are +ve"
		# return tboxes, positive_rois, negative_rois
		@show size(positive_rois)
		@show size(negative_rois)
		rois = vcat(positive_rois, negative_rois)
		# return rois, deltas, masks
		zs = zeros(Float32, negative_count)
		roi_gt_class_ids = vcat(roi_gt_class_ids, zs)
		zs = zeros(Float32, negative_count, 4) |> gpu
		deltas = vcat(deltas, zs)
		# return masks, deltas
		@show typeof(deltas)
		zs = zeros(Float32, MASK_SHAPE..., negative_count) |> gpu
		@show size(masks)
		@show size(zs)
		masks = cat(masks, zs, dims = 3)
		# return tboxes, masks
	elseif positive_count > 0
		rois = positive_rois
	elseif negative_count > 0
		rois = negative_rois
		zs = zeros(Float32, negative_count) |> gpu
		roi_gt_class_ids = zs
		zs = zeros(Float32, negative_count, 4) |> gpu
		deltas = zs
		zs = zeros(Float32, MASK_SHAPE..., negative_count) |> gpu
		@show "making everything bad again"
		masks = zs
	else
		rois = Float32[] |> gpu
		roi_gt_class_ids = Float32[] |> gpu
		deltas = Float32[] |> gpu
		masks = Float32[] |> gpu
	end

	@info "returning detection_target_layer"
	rois, roi_gt_class_ids, deltas, masks
end

function clip_to_window(window, boxes)
	boxes[:, 1] = clamp.(boxes[:, 1], window[1], window[3])
	boxes[:, 2] = clamp.(boxes[:, 2], window[2], window[4])
	boxes[:, 3] = clamp.(boxes[:, 3], window[1], window[3])
	boxes[:, 4] = clamp.(boxes[:, 4], window[2], window[4])
	boxes
end

function clip_to_window2(window, boxes)
	@show window
	b1 = clamp.(boxes[:, 1], window[1], window[3])
	b2 = clamp.(boxes[:, 2], window[2], window[4])
	b3 = clamp.(boxes[:, 3], window[1], window[3])
	b4 = clamp.(boxes[:, 4], window[2], window[4])

	hcat(b1, b2, b3, b4)
end

"""

"""
function refine_detections(rois, probs, deltas, window, config = nothing)
	# global grois = rois
	# global gprobs = probs
	# global gdeltas = deltas
	# global gwindow = window
	@show "in refine"
	@show size(probs)
	# gradient dropped here ?
	_, class_ids = findmax(Tracker.data(probs), dims = 1)
	@show size(deltas)
	@show size(probs)
	@show size(class_ids)
	# @show class_ids
	@warn "find max"
	idx = 1:length(class_ids)
	class_scores = vec(probs[class_ids])
	@show "maybe here"
	class_ids = vec(map(x -> x.I[1], class_ids))
	# @show idx
	# @show class_ids
	z = zip(idx, class_ids)
	# @show class_ids
	# @show idx
	# @show size(deltas)
	# @show size(rois)
	# @show size(probs)
	# deltas_specific = [deltas[x[1],:,x[2]] for x in z]
	# @show size(deltas_specific[1])
	# deltas_specific = reduce(hcat, deltas_specific)'
	# global gprobs = probs
	# global gclass_ids = class_ids
	# global gidx = idx
	# global gdeltas = deltas
	# deltas_specific = deltas[class_ids,:,idx]
	std_dev = [0.1 0.1 0.2 0.2] |> gpu
	@show "guess what"
	# deltas_specific .* std_dev
	deltas_specific = []
	# @show size(deltas_specific)
	for (m,k) in zip(idx, class_ids)
        push!(deltas_specific, deltas[k,:,m])
    end
    deltas_specific = cat(deltas_specific..., dims = 2)
	# @show size(deltas_specific' .* std_dev)
	# @show size(transpose(rois))
	refined_rois = apply_box_deltas(transpose(rois), transpose(deltas_specific) .* std_dev)
	@warn "applied deltas"
	height, width = 1024, 1024
	scale = [height width height width] |> gpu
	refined_rois = refined_rois .* scale
	refined_rois = clip_to_window2(window, refined_rois)
	@show typeof(refined_rois)
	refined_rois = round.(refined_rois)
	# @show refined_rois


	keep_bool = class_ids .> 0
	@show sum(keep_bool)
	DETECTION_MIN_CONFIDENCE = .5f0
	@show minimum(class_scores), mean(class_scores), maximum(class_scores)
	@show sum(class_scores .> DETECTION_MIN_CONFIDENCE)
	cs = copy(class_scores) |> cpu
	keep_bool = keep_bool .& (cs .>= DETECTION_MIN_CONFIDENCE)
	# @show sum(keep_bool), size(keep_bool)
	keep = findall(!iszero, keep_bool)
	@show keep
	pre_nms_class_ids = class_ids[keep]
	pre_nms_scores = class_scores[keep]
	# idxs = map(x -> x.I[1], findall(keep))
	pre_nms_rois = refined_rois[keep, :]

	unis = unique(pre_nms_class_ids) |> sort
	@warn "going to loop"
	nms_keep = Int[]
	for (i,class_id) in enumerate(unis)
		ixs = findall(pre_nms_class_ids .== class_id)

		ix_rois = pre_nms_rois[ixs, :]
		@show typeof(ix_rois)
		ix_scores = pre_nms_scores[ixs]
		order = sortperm(ix_scores, rev = true)
		ix_scores = ix_scores[order]
		ix_rois = ix_rois[order, :]
		# @show ix_rois
		DETECTION_NMS_THRESHOLD = 0.3f0
		class_keep = nms2(hcat(ix_rois .* 1.0f0, ix_scores), DETECTION_NMS_THRESHOLD)
		class_keep = keep[ixs[order[class_keep]]]
		if i==1
           push!(nms_keep, class_keep...)
        else
           push!(nms_keep, unique(class_keep)...)
        end
    end
    nms_keep = sort(nms_keep)
    keep = sort(intersect(keep, nms_keep))
    DETECTION_MAX_INSTANCES = 100
    roi_count = DETECTION_MAX_INSTANCES
	ends = min(roi_count, length(keep))
    top_ids = sortperm(class_scores[keep], rev = true)[1:ends]
    keep = keep[top_ids]


    @show size(refined_rois)
    @show size(class_ids)
    @show size(class_scores)

    # global grefined_rois = refined_rois
    # global gclass_ids = class_ids
    # global gclass_scores = class_scores
    # global gkeep = keep
    hcat(refined_rois[keep, :] .* 1.0f0, cu(class_ids[keep]) .* 1.0f0, class_scores[keep])

end

function detection_layer(rois, mrcnn_class, mrcnn_bbox, image_meta, config = nothing)
	_, _, window, _ = parse_image_meta(image_meta)
	@show size(rois)
	@show size(mrcnn_class)
	@show size(mrcnn_bbox)
	detections = refine_detections(transpose(rois), mrcnn_class, mrcnn_bbox, window, config)
	detections
end

function build_rpn_targets(image_shape, anchors, gt_class_ids, 
							gt_boxes, config = Nothing)
	RPN_TRAIN_ANCHORS_PER_IMAGE = 256
	RPN_BBOX_STD_DEV = [0.1f0, 0.1f0, 0.2f0, 0.2f0]
	rpn_match = zeros(Integer, size(anchors, 1))
	rpn_bbox = zeros(Float32, RPN_TRAIN_ANCHORS_PER_IMAGE, 4) |> gpu

	crowd_ix = findall(x -> x < 0, gt_class_ids)
	# crowd_ix = gt_class_ids .< 0
	if length(crowd_ix) > 0
		non_crowd_ix = setdiff(1:length(gt_class_ids), crowd_ix)
		crowd_boxes = gt_boxes[crowd_ix, :]
		gt_class_ids = gt_class_ids[non_crowd_ix]
		gt_boxes = gt_boxes[non_crowd_ix, :]
		crowd_overlaps = compute_overlaps(anchors, crowd_boxes)
		crowd_iou_max = maximum(crowd_overlaps, dims = 2)
        no_crowd_bool = findall(!iszero, crowd_iou_max .< 0.001f0)
    else
    	no_crowd_bool = trues(size(anchors, 1))
    end

    overlaps = compute_overlaps(anchors, gt_boxes)
    @show maximum(overlaps)
    @show size(overlaps)

    anchor_iou_argmax = argmax(overlaps, dims=2)
    @warn size(anchor_iou_argmax)
    anchor_iou_argmax = map(x -> x.I[2], anchor_iou_argmax)
    # @show size(overlaps)
    @show size(anchor_iou_argmax)
    # @show anchor_iou_argmax
    # anchor_iou_max = overlaps[1:size(overlaps, 1), anchor_iou_argmax]
    anchor_iou_max = vec(maximum(overlaps, dims = 2))
    # @show "here"
    # ins = findall(x -> x[1] < 0.3 & x[2], zip(anchor_iou_max, no_crowd_bool))
    # @show "after zip"
    # rpn_match[ins] .= -1
    @show size(anchor_iou_max)
    @show size(no_crowd_bool)
    inds = (anchor_iou_max .< .3f0) .& no_crowd_bool
    inds = findall(inds)
    rpn_match[inds] .= -1

    gt_iou_argmax = argmax(overlaps, dims = 1)
    # @show gt_iou_argmax
    gt_iou_argmax = map(x -> x.I[1], gt_iou_argmax)
    rpn_match[gt_iou_argmax] .= 1
    rpn_match[anchor_iou_max .>= 0.7f0] .= 1

    ids = findall(x -> x == 1, rpn_match)
    extra = length(ids) - div(RPN_TRAIN_ANCHORS_PER_IMAGE, 2)
    if extra > 0
    	ids = sample(ids, extra, replace = false)
    	rpn_match[ids] .= 0
    end

    ids = findall(x -> x == -1, rpn_match)
    extra = length(ids) - (RPN_TRAIN_ANCHORS_PER_IMAGE - sum(rpn_match .== 1))
    if extra > 0
    	ids = sample(ids, extra, replace = false)
    	rpn_match[ids] .= 0
    end

    ids = findall(x -> x == 1, rpn_match)
    ix = 1
    # @show anchors[ids,:]
    # @show ids
    # @show rpn_match
    for (i, a) in enumerate(eachrow(anchors[ids,:]))
    	i = ids[i]
    	# @show a
    	# @show anchor_iou_argmax[i]
    	gt = gt_boxes[anchor_iou_argmax[i], :]
	    # @show "here"
	    # @show gt

    	gt_h = gt[3] - gt[1]
        gt_w = gt[4] - gt[2]
        gt_center_y = gt[1] + (0.5f0 * gt_h)
        gt_center_x = gt[2] + (0.5f0 * gt_w)
        # Anchor
        a_h = a[3] - a[1]
        a_w = a[4] - a[2]
        a_center_y = a[1] + (0.5f0 * a_h)
        a_center_x = a[2] + (0.5f0 * a_w)

        # Compute the bbox refinement that the RPN should predict.
        rpn_bbox[ix, :] = gpu([
            (gt_center_y - a_center_y) / a_h,
            (gt_center_x - a_center_x) / a_w,
            log(gt_h / a_h), # remove abs - only for debugging
            log(gt_w / a_w),
        ] ./ RPN_BBOX_STD_DEV)
        # Normalize
        # rpn_bbox[ix, :] .= rpn_bbox[ix, :] ./ RPN_BBOX_STD_DEV
        ix += 1
    end
    rpn_match, rpn_bbox
end

# Loss Functions

function bce(ŷ, y; ϵ=cu(fill(eps(first(ŷ)), size(ŷ)...)))
    l1 = -y.*log.(ŷ .+ ϵ)
    l2 = (1 .- y).*log.(1 .- ŷ .+ ϵ)
    l1 .- l2
end

function compute_rpn_class_loss(rpn_match, rpn_class_logits; labels = 1:80)
	anchor_class = Int.(rpn_match .== 1)
	indices = findall(!iszero, rpn_match .!= 0)
	
	rpn_class_logits = rpn_class_logits[:, indices, :]
	rpn_class_logits = dropdims(rpn_class_logits, dims = ndims(rpn_class_logits))
	anchor_class = anchor_class[indices]
        
	anchor_class = Flux.onehotbatch(anchor_class, 0:1) |> gpu
	Flux.logitcrossentropy(rpn_class_logits, anchor_class)

end

function smooth_l1_loss(y, fx; δ = 1)
	α = abs(y - fx)
	abs(α) <= δ && return 0.5f0 * α ^ 2
	δ * α - (0.5f0 * δ ^ 2)
end

huber_loss(y, ŷ; kwargs...) = smooth_l1_loss(y, ŷ, kwargs...)

function compute_rpn_bbox_loss(target_bbox, rpn_match, rpn_bbox)
	inds = findall(rpn_match .== 1)

	rpn_bbox = rpn_bbox[:, inds, :]
	rpn_bbox = dropdims(rpn_bbox, dims = ndims(rpn_bbox))

	target_bbox = target_bbox[1:size(rpn_bbox,2), :]
	target_bbox = transpose(target_bbox)

	# smooth L1 loss
	mean(smooth_l1_loss.(target_bbox, rpn_bbox))
end

function compute_mrcnn_class_loss(target_class_ids, pred_class_logits; labels = 0:80)
	if length(target_class_ids) > 0
		target_class_ids = Int.(target_class_ids)
		y = Flux.onehotbatch(target_class_ids, labels) |> gpu
		return Flux.logitcrossentropy(pred_class_logits, y)
	else
		return param(0.0f0)
	end
end

function compute_mrcnn_bbox_loss(target_deltas, target_class_ids, pred_bbox; labels = 0:80)
	if length(target_class_ids) > 0
		target_class_ids = map(y -> findall(x -> x == y, labels)[1], target_class_ids)
		positive_roi_ix = findall(target_class_ids .> 0)

		positive_roi_class_ids = target_class_ids[positive_roi_ix]
		target_deltas = target_deltas[positive_roi_ix, :]
		target_deltas = transpose(target_deltas)
		# pred_bbox = pred_bbox[positive_roi_class_ids, :, positive_roi_ix]
		bb = []
		for i = 1:length(positive_roi_ix)
			a = pred_bbox[positive_roi_class_ids[i], :, i]
			push!(bb, a)
		end
		pred_bbox = reduce(hcat, bb)

		mean(smooth_l1_loss.(pred_bbox, target_deltas))
	else
		return param(0.0f0)
	end
end

function compute_mrcnn_mask_loss(target_mask, target_class_ids, mrcnn_mask; labels = 0:80)
	if length(target_class_ids) > 0
		target_class_ids = map(y -> findall(x -> x == y, labels)[1], target_class_ids)
		positive_ix = findall(target_class_ids .> 0.f0)
		positive_class_ids = target_class_ids[positive_ix]

		y_true = target_mask[:,:,positive_ix]
		bb = []
		for i = 1:length(positive_ix)
			a = mrcnn_mask[:,:,positive_class_ids[i], i]
			push!(bb, a)
		end
		y_pred = cat(bb..., dims = 3)
		# y_pred = cpu(y_pred)
		# y_true = cpu(y_true)

		mean(bce(y_pred, y_true))
	else
		return param(0.0f0)
	end
end

########################
# Data Generator

function mold_image(image, config = Nothing)
	MEAN_PIXEL = [123.7f0 / 255.0f0, 116.8f0 / 255.0f0, 103.9f0 / 255.0f0]
	# MEAN_PIXEL = [123.7f0, 116.8f0, 103.9]
	image[:,:,1] .-= MEAN_PIXEL[1]
	image[:,:,2] .-= MEAN_PIXEL[2]
	image[:,:,3] .-= MEAN_PIXEL[3]
	image
end

function compose_image_meta(image_id, image_shape, window, active_class_ids)
	([image_id], image_shape, window, active_class_ids)
end

parse_image_meta(image_meta) = image_meta

"""
	Take list of images (we will have them in the proper shape)

"""
function mold_inputs(images)
	IMAGE_MIN_DIM = 800
	IMAGE_MAX_DIM = 1024 # 128
	IMAGE_PADDING = true
	NUM_CLASSES = 81
	molded_images = []
    image_metas = []
    windows = []
	for image in images
		molded_image, window, scale, padding = resize_image(
			image,
            IMAGE_MIN_DIM,
            IMAGE_MAX_DIM,
            IMAGE_PADDING)

		molded_image = mold_image(molded_image)
		image_meta = compose_image_meta(0, size(image), window, zeros(Int32, NUM_CLASSES))
		push!(molded_images, molded_image)
		push!(windows, window)
		push!(image_metas, image_meta)
	end

	molded_images = cat(molded_images..., dims = 4)
	windows = reduce(hcat, windows)
	image_metas = reduce(hcat, image_metas)
	molded_images, image_metas, windows
end

