

const SCALING_FACTOR = 1_000_000

# use specialty type for "read counts"
# with basic function: 'sum' that can be
# overridden for more complex count bias models
const ReadCount = Float64

# This is where we count reads for nodes/edges/circular-edges/effective_lengths
# bias is an adjusting multiplier for nodecounts to bring them to the same level
# as junction counts, which should always be at a lower level, e.g. bias < 1
mutable struct SpliceGraphQuant
   node::Vector{ReadCount}
   edge::IntervalMap{ExonInt,ReadCount}
   circ::Dict{Tuple{ExonInt,ExonInt},ReadCount}
   leng::Vector{Float64}
   bias::Float64
end

# Default constructer
SpliceGraphQuant() = SpliceGraphQuant( Vector{ReadCount}(),
                                       IntervalMap{ExonInt,ReadCount}(),
                                       Dict{Tuple{ExonInt,ExonInt},ReadCount}(),
                                       Vector{Float64}(), 1.0 )

SpliceGraphQuant( sg::SpliceGraph ) = SpliceGraphQuant( zeros(ReadCount, length(sg.nodelen) ),
                                                        IntervalMap{ExonInt,ReadCount}(),
                                                        Dict{Tuple{ExonInt,ExonInt},ReadCount}(),
                                                        zeros( length(sg.nodelen) ), 1.0 )

# type-stable isoform compatibility class
mutable struct IsoCompat{T <: Tuple}
   class::T
   prop::Vector{Float64}
   prop_sum::Float64
   count::Float64

   function IsoCompat( tup::T, count::Float64 ) where T <: Tuple
      return IsoCompat{T}( tup, ones( length(tup) ) / length(tup), 1.0, count )
   end
end

# here we can quantify isoforms in a gene
# and store comptibility of reads
struct IsoQuant
   tpm::Vector{Float64}
   count::Vector{Float64}
   length::Vector{Int32}
   classes::Vector{IsoCompat}
end

IsoQuant() = IsoQuant( Vector{Float64}(), Vector{Float64}(), 
                       Vector{Int32}(), Vector{IsoCompat}() )

IsoQuant( sg::SpliceGraph ) = IsoQuant( zeros( length(sg.annoname) ),
                                        zeros( length(sg.annoname) ),
                                        map( x->Int32(sum(map( y->sg.nodelen[y], collect(x) ))), sg.annopath ),
                                        Vector{IsoCompat}() )

@inbounds function fill_isoquant!( graphq::GraphLibQuant, lib::GraphLib )
   # initialize re-used data structures
   iset = IntSet()
   resize!(iset.bits, 64)
   temp = Dict{Tuple,Float64}()

   @inline function handle_iset_value!( value )
      if length(iset) == 1
         graphq.compat[i].count[first(iset)] += sum(value)
      else
         tup = tuple(collect(iset))
         if haskey(temp, tup)
            temp[tup] += sum(value)
         else
            temp[tup] = sum(value)
         end
      end
   end

   # go through splice graphs (to re-use temp data structures)
   for i in 1:length(lib.graphs)
      # go through single node mapping reads
      for n in 1:length(graphq.quant[i].node)
         for p in 1:length(lib.graphs[i].annopath)
            if n in lib.graphs[i].annopath[p]
               push!(iset, p)
            end
         end
         handle_iset_value!( graphq.quant[i].node[n] )
         empty!(iset)
      end
      # go through edges
      for edg in graphq.quant[i].edge
         for p in 1:length(lib.graphs[i].annopath)
            if edg.first in lib.graphs[i].annopath[p] &&
               edg.last  in lib.graphs[i].annopath[p]
               push!(iset, p)
            end
         end
         handle_iset_value!( edg.value )
         empty!(iset)
      end
      # create compatibility classes for isoforms
      for tup in keys(temp)
         push!( graphq.compat[i].classes, IsoQuant(tup, temp[tup]) )
      end
      empty!(temp)
   end
end

# Here we store whole graphome quantification
struct GraphLibQuant
   tpm::Vector{Float64}
   count::Vector{Float64}
   compat::Vector{IsoQuant}
   quant::Vector{SpliceGraphQuant}
end

function GraphLibQuant( lib::GraphLib )
   tpm    = zeros( length(lib.graphs) )
   count  = zeros( length(lib.graphs) )
   isoq   = Vector{IsoQuant}( length(lib.graphs) )
   quant  = Vector{SpliceGraphQuant}( length(lib.graphs) )
   for i in 1:length( lib.graphs )
      isoq[i]  = IsoQuant( lib.graphs[i] )
      quant[i] = SpliceGraphQuant( lib.graphs[i] )
   end
   GraphLibQuant( tpm, count, isoq, quant )
end

@inline function calculate_tpm!( quant::GraphLibQuant, counts::Vector{Float64}=quant.count; readlen::Int64=50, sig::Int64=1 )
   for i in 1:length(counts)
      @fastmath quant.tpm[ i ] = counts[i] / max( (quant.length[i] - readlen), 1.0 )
   end
   const rpk_sum = max( sum( quant.tpm ), 1.0 )
   for i in 1:length(quant.tpm)
      if sig > 0
         @fastmath quant.tpm[i] = round( quant.tpm[i] * SCALING_FACTOR / rpk_sum, sig )
      else
         @fastmath quant.tpm[i] = ( quant.tpm[i] * SCALING_FACTOR / rpk_sum )
      end
   end
end



const MultiAln = Vector{SGAlignPath}

mutable struct MultiAssign
   prop::Vector{Float64}
   prop_sum::Float64
   count::ReadCount
end

# This hash structure stores multi-mapping
# equivalence classes
const MultiCompat = Dict{MultiAln,MultiAssign}

#=
mutable struct Multimap
   align::Vector{SGAlignment}
   prop::Vector{Float64}
   prop_sum::Float64
end
=#

Multimap( aligns::Vector{SGAlignment} ) = length(aligns) >= 1 ? 
                                    Multimap( aligns, ones(length(aligns)) / length(aligns), 1.0 ) :
                                    Multimap( aligns, Float64[], 0.0 )


function assign_ambig!( graphq::GraphLibQuant, ambig::Vector{Multimap}; ispaired::Bool=false )
   for mm in ambig
      i = 1
      while i <= length(mm.prop)
         if ispaired
            (i == length(mm.prop)) && break
            count!( graphq, mm.align[i], mm.align[i+1], val=mm.prop[i] )
            i += 1
         else
            count!( graphq, mm.align[i], val=mm.prop[i] )
         end
         i += 1
      end
   end
end

function count!( graphq::GraphLibQuant, align::SGAlignment; val::Float64=1.0 )
   align.isvalid == true || return
   init_gene = align.path[1].gene
   sgquant   = graphq.quant[ init_gene ]

   graphq.count[ init_gene ] += 1
   
   if length(align.path) == 1
      # access node -> [ SGNode( gene, *node* ) ]
      sgquant.node[ align.path[1].node ] += val
   else
      # TODO: potentially handle trans-splicing here via align.istrans variable?
      
      # Otherwise, lets step through pairs of nodes and add val to those edges
      for n in 1:(length(align.path)-1)
         # trans-spicing off->
         align.path[n].gene != init_gene && continue
         align.path[n+1].gene != init_gene && continue
         lnode = align.path[n].node
         rnode = align.path[n+1].node
         if lnode < rnode
            interv = Interval{ExonInt}( lnode, rnode )
            sgquant.edge[ interv ] = get( sgquant.edge, interv, IntervalValue(0,0,0.0) ).value + val
         elseif lnode >= rnode
            sgquant.circ[ (lnode, rnode) ] = get( sgquant.circ, (lnode,rnode), 0.0) + val
         end
      end
   end
end

function calculate_bias!( sgquant::SpliceGraphQuant )
   edgecnt = 0.0
   for edgev in sgquant.edge
      edgecnt += edgev.value
   end
   @fastmath edgelevel = edgecnt / length(sgquant.edge)
   nodecnt = 0.0
   for nodev in sgquant.node
      nodecnt += nodev
   end
   @fastmath nodelevel = nodecnt / sum( sgquant.leng )
   # never down-weight junction reads, only exon-body reads
   bias = @fastmath min( edgelevel / nodelevel, 1.0 )
   sgquant.bias = bias
   bias
end

function global_bias( graphq::GraphLibQuant )
   bias_ave = 0.0
   bias_var = 0.0
   n = 1
   for sgq in graphq.quant
      curbias = calculate_bias!( sgq )
      if curbias > 10
         println( sgq )
      end
      old = bias_ave
      @fastmath bias_ave += (curbias - bias_ave) / n
      if n > 1
        @fastmath bias_var += (curbias - old)*(curbias - bias_ave)
      end
      n += 1
   end
   bias_ave,bias_var
end

# Every exon-exon junction has an effective mappable space of readlength - K*2.
# Since we only count nodes that don't map over edges, we can give
# give each junction an effective_length of one, and now the space
# inside of a node for which a read could map without overlapping a junction
# is put into units of junction derived effective_length
# kadj is minimum of (readlength - minalignlen) and k-1
@inline function eff_length( node, sg::SpliceGraph, eff_len::Int, kadj::Int )
   len = sg.nodelen[node] + (istxstart( sg.edgetype[node] ) ? 0 : kadj) +
                            (istxstop( sg.edgetype[node+1] ) ? 0 : kadj)
   @fastmath len / eff_len
end

function eff_lengths!( sg::SpliceGraph, sgquant::SpliceGraphQuant, eff_len::Int, kadj::Int )
   for i in 1:length( sg.nodelen )
      sgquant.leng[i] = eff_length( i, sg, eff_len, kadj )
   end
end

function effective_lengths!( lib::GraphLib, graphq::GraphLibQuant, eff_len::Int, kadj::Int )
   for i in 1:length( lib.graphs )
      eff_lengths!( lib.graphs[i], graphq.quant[i], eff_len, kadj )
   end
end

function Base.unsafe_copy!{T <: Number}( dest::Vector{T}, src::Vector{T}; indx_shift=0 )
   for i in 1:length(src)
      dest[i+indx_shift] = src[i]
   end
end

# This function performs expectation maximization
# and sets the quant.tpm array as the proposed expression set
# at each iteration.   It also requires that calculate_tpm! be 
# run initially once prior to gene_em!() call.

function gene_em!( quant::GraphLibQuant, ambig::Vector{Multimap};
                   it::Int64=1, maxit::Int64=1000, sig::Int64=1, readlen::Int64=50 )

   const count_temp = ones(length(quant.count))
   const tpm_temp   = ones(length(quant.count))
   const uniqsum    = sum(quant.count)
   const ambigsum   = length(ambig)

   while tpm_temp != quant.tpm && it < maxit

      unsafe_copy!( count_temp, quant.count )
      unsafe_copy!( tpm_temp, quant.tpm )

      for mm in ambig
         if it > 1 # Maximization
            mm.prop_sum = 0.0
            for ai in 1:length(mm.align)
               const init_gene = mm.align[ai].path[1].gene
               const init_tpm  = quant.tpm[ init_gene ] * max( quant.length[ init_gene ] - readlen, 1.0 )
               mm.prop[ai] = init_tpm
               @fastmath mm.prop_sum += init_tpm
            end
         end

         for ai in 1:length(mm.align)
            const init_gene = mm.align[ai].path[1].gene
            @fastmath const prop = mm.prop[ai] / mm.prop_sum
            mm.prop[ai] = isnan(prop) ? 0.0 : prop
            @fastmath count_temp[ init_gene ] += mm.prop[ai]
         end
      end

      calculate_tpm!( quant, count_temp, sig=sig, readlen=readlen ) # Expectation
 
      it += 1
   end
   it
end


function output_tpm( file, lib::GraphLib, gquant::GraphLibQuant )
   io = open( file, "w" )
   stream = ZlibDeflateOutputStream( io )
   output_tpm_header( stream )
   for i in 1:length(lib.names)
      tab_write( stream, lib.names[i] )
      tab_write( stream, string(gquant.tpm[i]) )
      tab_write( stream, string(gquant.count[i]) )
      write( stream, '\n' )
   end
   close( stream )
   close( io )
end
