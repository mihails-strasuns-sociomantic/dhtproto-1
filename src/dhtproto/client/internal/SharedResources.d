/*******************************************************************************

    Neo DHT client shared resources, available to all request handlers.

    Copyright:
        Copyright (c) 2017 sociomantic labs GmbH. All rights reserved.

    License:
        Boost Software License Version 1.0. See LICENSE.txt for details.

*******************************************************************************/

module dhtproto.client.internal.SharedResources;

import ocean.transition;

/// ditto
public final class SharedResources
{
    import swarm.neo.util.AcquiredResources;
    import dhtproto.client.internal.NodeHashRanges;
    import swarm.neo.client.ConnectionSet;
    import ocean.util.container.pool.FreeList;
    import ocean.core.TypeConvert : downcast;
    import ocean.io.compress.Lzo;
    import swarm.neo.request.RequestEventDispatcher;
    import swarm.neo.util.MessageFiber;
    import swarm.util.RecordBatcher;

    /// Global NodeHashRanges instance
    private NodeHashRanges node_hash_ranges_;

    /// Free list of recycled buffers
    private FreeList!(ubyte[]) buffers;

    /// Free list of RequestEventDispatcher instances
    private FreeList!(RequestEventDispatcher) request_event_dispatchers;

    /// Free list of MessageFiber instances
    private FreeList!(MessageFiber) fibers;

    /// Free list of RecordBatch instances
    private FreeList!(RecordBatch) record_batches;

    /// Lzo instance shared by all record batches (newed on demand)
    private Lzo lzo_;

    /***************************************************************************

        A SharedResources instance is stored in the ConnectionSet as an Object.
        This helper function safely casts from this Object to a correctly-typed
        instance.

        Params:
            obj = object to cast from

        Returns:
            obj cast to SharedResources

    ***************************************************************************/

    public static SharedResources fromObject ( Object obj )
    {
        auto shared_resources = downcast!(SharedResources)(obj);
        assert(shared_resources !is null);
        return shared_resources;
    }

    /***************************************************************************

        Constructor.

    ***************************************************************************/

    this ( )
    {
        this.buffers = new FreeList!(ubyte[]);
        this.request_event_dispatchers = new FreeList!(RequestEventDispatcher);
        this.fibers = new FreeList!(MessageFiber);
        this.record_batches = new FreeList!(RecordBatch);
    }

    /***************************************************************************

        Sets the shared NodeHashRanges instance. (This cannot be done in a ctor,
        because the NodeHashRanges instance requires a ConnectionSet, which is
        owned by the Neo object, which requires a SharedResources instance to be
        passed to its ctor.)

        Params:
            node_hash_ranges = NodeHashRanges owned by the client

    ***************************************************************************/

    public void setNodeHashRanges ( NodeHashRanges node_hash_ranges )
    {
        this.node_hash_ranges_ = node_hash_ranges;
    }

    /***************************************************************************

        Returns:
            shared NodeHashRanges instance

    ***************************************************************************/

    public NodeHashRanges node_hash_ranges ( )
    {
        return this.node_hash_ranges_;
    }

    /***************************************************************************

        Returns:
            shared Lzo instance

    ***************************************************************************/

    private Lzo lzo ( )
    {
        if ( this.lzo_ is null )
            this.lzo_ = new Lzo;

        return this.lzo_;
    }

    /***************************************************************************

        Class to track the resources acquired by a request and relinquish them
        (recylcing them into the shared resources pool) when the request
        finishes. An instance should be newed as a request is started and
        destroyed as it finishes. Newing an instance as `scope` is the most
        convenient way.

    ***************************************************************************/

    public class RequestResources
    {
        /// Set of acquired buffers of NodeHashRange
        private AcquiredArraysOf!(NodeHashRange) acquired_node_hash_range_buffers;

        /// Acquired RequestEventDispatcher singleton
        private AcquiredSingleton!(RequestEventDispatcher)
            acquired_request_event_dispatcher;

        /// Set of acquired fibers
        private Acquired!(MessageFiber) acquired_fibers;

        /// Set of acquired record batches
        private Acquired!(RecordBatch) acquired_record_batches;

        /***********************************************************************

            Constructor.

        ***********************************************************************/

        this ( )
        {
            this.acquired_node_hash_range_buffers.initialise(this.outer.buffers);
            this.acquired_request_event_dispatcher.initialise(
                this.outer.request_event_dispatchers);
            this.acquired_fibers.initialise(this.outer.buffers,
                this.outer.fibers);
            this.acquired_record_batches.initialise(this.outer.buffers,
                this.outer.record_batches);
        }

        /***********************************************************************

            Destructor. Relinquishes any acquired resources.

        ***********************************************************************/

        ~this ( )
        {
            this.acquired_node_hash_range_buffers.relinquishAll();
            this.acquired_request_event_dispatcher.relinquish();
            this.acquired_fibers.relinquishAll();
            this.acquired_record_batches.relinquishAll();
        }

        /***********************************************************************

            Returns:
                a new NodeHashRange buffer acquired from the shared resources
                pools

        ***********************************************************************/

        public NodeHashRange[]* getNodeHashRangeBuffer ( )
        {
            return this.acquired_node_hash_range_buffers.acquire();
        }

        /***********************************************************************

            Gets a fiber from the shared resources pool and assigns the provided
            delegate as its entry point.

            Params:
                fiber_method = entry point to assign to acquired fiber

            Returns:
                a new MessageFiber acquired from the shared resources pools

        ***********************************************************************/

        public MessageFiber getFiber ( void delegate ( ) fiber_method )
        {
            bool new_fiber = false;

            MessageFiber newFiber ( )
            {
                new_fiber = true;
                return new MessageFiber(fiber_method, 64 * 1024);
            }

            auto fiber = this.acquired_fibers.acquire(newFiber());
            if (!new_fiber)
                fiber.reset(fiber_method);

            return fiber;
        }

        /***********************************************************************

            Gets a record batch from the shared resources pool.

            Returns:
                a new record batch acquired from the shared resources pools

        ***********************************************************************/

        public RecordBatch getRecordBatch ( )
        {
            auto batch = this.acquired_record_batches.acquire(
                new RecordBatch(this.outer.lzo()));
            batch.clear();
            return batch;
        }

        /***********************************************************************

            Returns:
                pointer to singleton RequestEventDispatcher instance

        ***********************************************************************/

        public RequestEventDispatcher* request_event_dispatcher ( )
        {
            return this.acquired_request_event_dispatcher.acquire(
                new RequestEventDispatcher,
                ( RequestEventDispatcher* dispatcher )
                {
                    dispatcher.reset();
                }
            );
        }
    }
}