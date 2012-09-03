#pragma OPENCL EXTENSION cl_khr_global_int32_base_atomics : enable
#pragma OPENCL EXTENSION cl_khr_global_int32_extended_atomics : enable
#pragma OPENCL EXTENSION cl_khr_byte_addressable_store: enable

#define CELL_GRASS_OFFSET 0
#define CELL_NUMAGENTS_OFFSET 1
#define CELL_AGINDEX_OFFSET 2

#define SHEEP_ID 0
#define WOLF_ID 1
#define GRASS_ID 2
#define TOTALAGENTS_ID 3

typedef struct agent_params {
	uint gain_from_food;
	uint reproduce_threshold;
	uint reproduce_prob; /* between 1 and 100 */
} AGENT_PARAMS;

typedef struct sim_params {
	uint size_x;
	uint size_y;
	uint size_xy;
	uint max_agents;
	uint grass_restart;
	uint grid_cell_space;
} SIM_PARAMS;

typedef struct agent {
	uint x;
	uint y;
	uint alive;
	ushort energy;
	ushort type;
} AGENT __attribute__ ((aligned (16)));

/*
 * RNG utility function, not to be called directly from kernels.
 */
uint randomNext( __global ulong * seeds, 
			uint bits) {

	// Global id for this work-item
	uint gid = get_global_id(0);
	// Get current seed
	ulong seed = seeds[gid];
	// Update seed
	seed = (seed * 0x5DEECE66DL + 0xBL) & ((1L << 48) - 1);
	// Keep seed
	seeds[gid] = seed;
	// Return value
	return (uint) (seed >> (48 - bits));
}

/*
 * Random number generator. Returns next integer from 0 (including) to n (not including).
 */
uint randomNextInt( __global ulong * seeds, 
			uint n)
{
	if ((n & -n) == n)  // i.e., n is a power of 2
		return (uint) (n * (((ulong) randomNext(seeds, 31)) >> 31));
	uint bits, val;
	do {
		bits = randomNext(seeds, 31);
		val = bits % n;
	} while (bits - val + (n-1) < 0);
	return val;
}

/*
 * Agent movement kernel
 */
__kernel void RandomWalk(__global AGENT * agents,
				__global ulong * seeds,
				const SIM_PARAMS sim_params)
{
	// Global id for this work-item
	uint gid = get_global_id(0);
	// Pseudo-randomly determine direction
	AGENT agent = agents[gid];
	if (agent.alive)
	{
		uint direction = randomNextInt(seeds, 5);
		// Perform the actual walk
		if (direction == 1) 
		{
			agent.x++;
			if (agent.x >= sim_params.size_x) agent.x = 0;
		}
		else if (direction == 2) 
		{
			if (agent.x == 0)
				agent.x = sim_params.size_x - 1;
			else
				agent.x--;
		}
		else if (direction == 3)
		{
			agent.y++;
			if (agent.y >= sim_params.size_y) agent.y = 0;
		}
		else if (direction == 4)
		{
			if (agent.y == 0)
				agent.y = sim_params.size_y - 1;
			else
				agent.y--;
		}
		// Lose energy
		agent.energy--;
		if (agent.energy < 1)
			agent.alive = 0;
		// Update global mem
		agents[gid] = agent;
	}
}

/*
 * Update agents in grid
 */
__kernel void AgentsUpdateGrid(__global AGENT * agents, 
			__global uint * matrix,
			const SIM_PARAMS sim_params)
{
	// Global id for this work-item
	uint gid = get_global_id(0);
	// Get my agent
	AGENT agent = agents[gid];
	if (agent.alive) {
		// Update grass matrix by...
		uint index = sim_params.grid_cell_space*(agent.x + sim_params.size_x * agent.y);
		// ...increment number of agents...
		atom_inc(&matrix[index + CELL_NUMAGENTS_OFFSET]);
		// ...and setting lowest agent vector index with agents in this place.
		atom_min(&matrix[index + CELL_AGINDEX_OFFSET], gid); 
	}
}


/*
 * Bitonic sort kernel
 */
__kernel void BitonicSort(__global AGENT * agents,
				const uint stage,
				const uint step)
{
	// Global id for this work-item
	uint gid = get_global_id(0);

	// Determine what to compare and possibly swap
	uint pair_stride = (uint) 1 << (step - 1);
	uint index1 = gid + (gid / pair_stride) * pair_stride;
	uint index2 = index1 + pair_stride;
	// Get values from global memory
	AGENT agent1 = agents[index1];
	AGENT agent2 = agents[index2];
	// Determine if ascending or descending
	bool desc = (bool) (0x1 & (gid >> stage - 1));
	// Determine if agent1 > agent2 according to our criteria
	bool gt = 0;

	if (agent2.alive)
	{
		if (!agent1.alive) 
		{
			// If agent is dead, we want to put it in end of list, so we set "greater than" = true
			gt = 1;
		}
		else if (agent1.x > agent2.x)
		{
			// x is the main dimension to check if value1 is "greater than" value2
			gt = 1;
		}
		else if (agent1.x == agent2.x)
		{
			// Break tie by checking y position
			gt = agent1.y > agent2.y;
		}
	}

	/* Perform swap if needed */ 
	if ( (desc && !gt) || (!desc && gt))
	{
		//swap = 1;
		agents[index1] = agent2;
		agents[index2] = agent1;
	}


}


/*
 * Grass kernel
 */
__kernel void Grass(__global uint * matrix, 
			const SIM_PARAMS sim_params)
{
	// Grid position for this work-item
	uint x = get_global_id(0);
	uint y = get_global_id(1);
	// Check if this thread will do anything
	if ((x < sim_params.size_x) && (y < sim_params.size_y)) {
		// Decrement counter if grass is dead
		uint index = sim_params.grid_cell_space*(x + sim_params.size_x * y);
		if (matrix[index] > 0)
			matrix[index]--;
		// Set number of agents in this place to zero
		matrix[index + CELL_NUMAGENTS_OFFSET] = 0;
		matrix[index + CELL_AGINDEX_OFFSET] = sim_params.max_agents;
	}
}


/*
 * Reduction code for grass count kernels. Makes use of the fact that the number of agents is a base of 2.
 */
void reduceAgents(__local uint2 * lcounter, uint lid) 
{
	barrier(CLK_LOCAL_MEM_FENCE);
	/* Determine number of stages/loops. */
	uint stages = 8*sizeof(uint) - clz(get_local_size(0)) - 1;
	/* Perform loops/stages. */
	for (int i = 0; i < stages; i++) {
		uint stride = (uint) 1 << i; //round(pown(2.0f, i));
		uint divisible = (uint) stride * 2;
		if ((lid % divisible) == 0) {
			if (lid + stride < get_local_size(0)) {
				lcounter[lid] += lcounter[lid + stride];
			}
		}
		barrier(CLK_LOCAL_MEM_FENCE);
	}
}
/*
 * Count agents part 1.
 */
__kernel void CountAgents1(__global AGENT * agents,
			__global uint2 * gcounter,
			__local uint2 * lcounter)
{
	uint gid = get_global_id(0);
	uint lid = get_local_id(0);
	if (agents[gid].alive) {
		uint agentType = agents[gid].type;
		if (agentType == 0) {
			lcounter[lid] = (uint2) (1, 0);
		} else {
			lcounter[lid] = (uint2) (0, 1);
		}
	} else {
		lcounter[lid] = (uint2) (0, 0);
	}
	reduceAgents(lcounter, lid);
	if (lid == 0) {
		gcounter[get_group_id(0)] = lcounter[lid];
	}
}
/*
 * Count agents part 2.
 */
__kernel void CountAgents2(__global uint2 * gcounter,
			__local uint2 * lcounter,
			__global uint * stats)
{
	uint lid = get_local_id(0);
	lcounter[lid].x = gcounter[lid].x;
	lcounter[lid].y = gcounter[lid].y;
	barrier(CLK_LOCAL_MEM_FENCE);
	reduceAgents(lcounter, lid);
	if (lid == 0) {
		stats[SHEEP_ID] = lcounter[lid].x;
		stats[WOLF_ID] = lcounter[lid].y;
		stats[TOTALAGENTS_ID] = lcounter[lid].x + lcounter[lid].y;
	}
	
}


/*
 * Reduction code for grass count kernels
 */
void reduceGrass(__local uint * lcounter, uint lid) 
{
	barrier(CLK_LOCAL_MEM_FENCE);
	/* Determine number of stages/loops. */
	uint lsbits = 8*sizeof(uint) - clz(get_local_size(0)) - 1;
	uint stages = ((1 << lsbits) == get_local_size(0)) ? lsbits : lsbits + 1;
	/* Perform loops/stages. */
	for (int i = 0; i < stages; i++) {
		uint stride = (uint) 1 << i; //round(pown(2.0f, i));
		uint divisible = (uint) stride * 2;
		if ((lid % divisible) == 0) {
			if (lid + stride < get_local_size(0)) {
				lcounter[lid] += lcounter[lid + stride];
			}
		}
		barrier(CLK_LOCAL_MEM_FENCE);
	}
}

/*
 * Count grass part 1.
 */
__kernel void CountGrass1(__global uint * grass,
			__global uint * gcounter,
			__local uint * lcounter,
			const SIM_PARAMS sim_params)
{
	uint gid = get_global_id(0);
	uint lid = get_local_id(0);
	// Check if this thread will do anything
	if (gid < sim_params.size_xy) {
		lcounter[lid] = (grass[gid * sim_params.grid_cell_space] == 0 ? 1 : 0);
		reduceGrass(lcounter, lid);
		if (lid == 0)
			gcounter[get_group_id(0)] = lcounter[lid];
	}
}

/*
 * Count grass part 2.
 */
__kernel void CountGrass2(__global uint * gcounter,
			__local uint * lcounter,
			__global uint * stats)
{
	uint gid = get_global_id(0);
	// Check if this thread will do anything
	uint lid = get_local_id(0);
	lcounter[lid] = gcounter[gid];
	barrier(CLK_LOCAL_MEM_FENCE);
	reduceGrass(lcounter, lid);
	if (gid == 0)
		stats[GRASS_ID] = lcounter[0];
}

/*
 * Agent reproduction function for agents action kernel
 */
AGENT agentReproduction(__global AGENT * agents, AGENT agent, __global AGENT_PARAMS * params, __global uint * stats, __global ulong * seeds)
{
	// Perhaps agent will reproduce if energy > reproduce_threshold
	if (agent.energy > params[agent.type].reproduce_threshold) {
		// Throw some kind of dice to see if agent reproduces
		if (randomNextInt(seeds, 100) < params[agent.type].reproduce_prob ) {
			// Agent will reproduce! Let's see if there is space...
			AGENT newAgent;
			uint position = atom_inc( &stats[TOTALAGENTS_ID] );
			if (position < get_global_size(0) - 2)
			{
				// There is space, lets put new agent!
				newAgent = agent;
				newAgent.energy = newAgent.energy / 2;
				agents[position] = newAgent;
			}
			// Current agent's energy will be halved also
			agent.energy = agent.energy - newAgent.energy;			
		}
	}
	return agent;
}

/*
 * Sheep actions
 */
AGENT sheepAction( AGENT sheep,
		__global uint * matrix, 
		const SIM_PARAMS sim_params, 
		__global AGENT_PARAMS * params)
{
	// If there is grass, eat it (and I can be the only one to do so)!
	uint index = (sheep.x + sheep.y * sim_params.size_x) * sim_params.grid_cell_space;
	uint grassState = atom_cmpxchg(&matrix[index], (uint) 0, (uint) sim_params.grass_restart);
	if (grassState == 0) {
		// There is grass, sheep eats it and gains energy (if wolf didn't eat her mean while!)
		sheep.energy += params[SHEEP_ID].gain_from_food;
	}
	return sheep;
}

/*
 * Wolf actions
 */
AGENT wolfAction( AGENT wolf,
		__global AGENT * agents,
		__global uint * matrix,
		const SIM_PARAMS sim_params, 
		__global AGENT_PARAMS * params)
{
	// Get index of this location
	uint index = (wolf.x + wolf.y * sim_params.size_x) * sim_params.grid_cell_space;
	// Get number of agents here
	uint numAgents = matrix[index + CELL_NUMAGENTS_OFFSET];
	if (numAgents > 0) {
		// Get starting index of agents here from agent array
		uint agentsIndex = matrix[index + CELL_AGINDEX_OFFSET];
		// Cycle through agents
		for (int i = 0; i < numAgents; i++) {
			if (agents[agentsIndex + i].type == SHEEP_ID) {
				// If it is a sheep, try to eat it!
				uint isSheepAlive = atom_cmpxchg(&(agents[agentsIndex + i].alive), 1, 0);
				if (isSheepAlive) {
					// If I catch sheep, I'm satisfied for now, let's get out of this loop
					wolf.energy += params[WOLF_ID].gain_from_food;
					break;
				}
			}
		}
	}
	// Return wolf after action taken...
	return wolf;
}


/*
 * Agents action kernel
 */
__kernel void AgentAction( __global AGENT * agents, 
			__global uint * matrix, 
			const SIM_PARAMS sim_params, 
			__global AGENT_PARAMS * params,
			__global ulong * seeds,
			__global uint * stats/*,
			__global uint8 * debug*/)
{
	// Global id for this work-item
	uint gid = get_global_id(0);
	// Get my agent
	AGENT agent = agents[gid];
	// If agent is alive, do stuff
	if (agent.alive) {
		// Perform specific agent actions
		switch (agent.type) {
			case SHEEP_ID : agent = sheepAction(agent, matrix, sim_params, params); break;
			case WOLF_ID : agent = wolfAction(agent, agents, matrix, sim_params, params); break;
			default : break;
		}
		// Try reproducing this agent
		agent = agentReproduction(agents, agent, params, stats, seeds);
		// My actions only affect my energy, so I will only put back energy...
		agents[gid].energy = agent.energy;
	}
}



